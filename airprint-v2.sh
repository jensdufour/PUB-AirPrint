#!/usr/bin/env bash
# airprint-v2.sh — Proxmox host bootstrap.
#
# One-liner usage (run on the Proxmox node, as root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jensdufour/PUB-AirPrint/main/airprint-v2.sh)"
#
# What it does:
#   1. Validates Proxmox + root.
#   2. Prompts for container/network/printer settings (or reads AIRPRINT_* env).
#   3. Ensures a Debian 12 LXC template is available locally.
#   4. Creates an unprivileged LXC.
#   5. Clones this repo into the container at /opt/airprint-v2.
#   6. Runs install.sh inside the container.
#
# Configuration is overridable via env (see README for full list).

# ---- where this script lives & where to fetch the rest from ---------------
# Override REPO_URL/REPO_BRANCH if you forked the repo or work off a branch.
: "${AIRPRINT_REPO_URL:=https://github.com/jensdufour/PUB-AirPrint.git}"
: "${AIRPRINT_REPO_BRANCH:=main}"
: "${AIRPRINT_REPO_RAW:=https://raw.githubusercontent.com/jensdufour/PUB-AirPrint/${AIRPRINT_REPO_BRANCH}}"

# ---- bootstrap: source common.sh whether running locally or via curl-bash --
if __self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"; then
  :
else
  __self_dir=""
fi
if [[ -n "$__self_dir" && -f "$__self_dir/lib/common.sh" ]]; then
  # Running from a local checkout.
  # shellcheck source=lib/common.sh
  source "$__self_dir/lib/common.sh"
  # shellcheck source=lib/host_prompts.sh
  source "$__self_dir/lib/host_prompts.sh"
  AIRPRINT_LOCAL_CHECKOUT="$__self_dir"
else
  # Running via `bash -c "$(curl ...)"` — pull lib files from raw.
  AIRPRINT_LOCAL_CHECKOUT=""
  __tmpdir="$(mktemp -d)"
  trap 'rm -rf "$__tmpdir"' EXIT
  for f in lib/common.sh lib/host_prompts.sh; do
    mkdir -p "$__tmpdir/$(dirname "$f")"
    curl -fsSL "$AIRPRINT_REPO_RAW/$f" -o "$__tmpdir/$f" \
      || { echo "ERROR: failed to fetch $f from $AIRPRINT_REPO_RAW" >&2; exit 1; }
  done
  # shellcheck source=/dev/null
  source "$__tmpdir/lib/common.sh"
  # shellcheck source=/dev/null
  source "$__tmpdir/lib/host_prompts.sh"
fi

# ---- preflight ------------------------------------------------------------
require_root
need_cmd pct
need_cmd pveam
need_cmd pvesm
[[ -f /etc/pve/.version ]] || warn "no /etc/pve/.version — are you sure this is a Proxmox node?"

# ---- gather config --------------------------------------------------------
run_host_wizard

# ---- ensure Debian 12 template is local -----------------------------------
ensure_template() {
  local store="$AIRPRINT_TPL_STORAGE" tpl
  log "looking for a Debian 12 LXC template on '$store'…"
  # Use awk's exit, not `| head -n1`, to avoid SIGPIPE on the producer.
  tpl="$(pveam list "$store" 2>/dev/null | awk '/debian-12.*standard.*\.tar\.(zst|gz|xz)$/ {print $1; exit}')"
  if [[ -n "$tpl" ]]; then
    AIRPRINT_TEMPLATE_REF="$tpl"
    ok "found template: $AIRPRINT_TEMPLATE_REF"
    return
  fi
  log "no local template — refreshing template index"
  pveam update >/dev/null
  local pkg
  pkg="$(pveam available --section system | awk '/^system *debian-12-standard/ {print $2}' | sort -V | tail -n1)"
  [[ -n "$pkg" ]] || die "no debian-12-standard template available from pveam"
  log "downloading $pkg to $store…"
  pveam download "$store" "$pkg"
  AIRPRINT_TEMPLATE_REF="${store}:vztmpl/${pkg}"
  ok "template ready: $AIRPRINT_TEMPLATE_REF"
}
ensure_template

# ---- build the `pct create` argument list ---------------------------------
build_net_arg() {
  local n="name=eth0,bridge=$AIRPRINT_BRIDGE"
  [[ -n "$AIRPRINT_VLAN" ]] && n="$n,tag=$AIRPRINT_VLAN"
  if [[ "$AIRPRINT_IP" == "dhcp" ]]; then
    n="$n,ip=dhcp,ip6=auto"
  else
    n="$n,ip=$AIRPRINT_IP"
    [[ -n "${AIRPRINT_GATEWAY:-}" ]] && n="$n,gw=$AIRPRINT_GATEWAY"
    n="$n,ip6=auto"
  fi
  printf '%s' "$n"
}

generate_root_password() {
  # 24 chars, no shell-hostile bytes.
  # Read a fixed-size chunk of /dev/urandom *first*, THEN filter — this avoids
  # the classic `tr ... < /dev/urandom | head -c N` SIGPIPE-141 trap when the
  # script runs under `set -o pipefail` (head closes the pipe before tr is
  # done draining the infinite random source).
  local raw
  raw="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9_=+-')"
  printf '%s' "${raw:0:24}"
}

if [[ -z "${AIRPRINT_ROOT_PW:-}" ]]; then
  AIRPRINT_ROOT_PW="$(generate_root_password)"
fi

# If the CTID is already in use, offer to re-run the in-container installer
# instead of refusing — handy when iterating on the scripts.
AIRPRINT_REUSE_CT=0
if pct status "$AIRPRINT_CTID" >/dev/null 2>&1; then
  warn "CTID $AIRPRINT_CTID already exists"
  if confirm "Reuse it and just re-run the in-container installer?" "y"; then
    AIRPRINT_REUSE_CT=1
  else
    die "aborted — destroy CT $AIRPRINT_CTID first or pick a different CTID"
  fi
fi

if (( AIRPRINT_REUSE_CT == 0 )); then
  NET_ARG="$(build_net_arg)"
  log "creating LXC $AIRPRINT_CTID ($AIRPRINT_HOSTNAME) on $AIRPRINT_STORAGE"
  pct create "$AIRPRINT_CTID" "$AIRPRINT_TEMPLATE_REF" \
    --hostname    "$AIRPRINT_HOSTNAME" \
    --cores       "$AIRPRINT_CORES" \
    --memory      "$AIRPRINT_RAM" \
    --swap        256 \
    --rootfs      "${AIRPRINT_STORAGE}:${AIRPRINT_DISK}" \
    --net0        "$NET_ARG" \
    --unprivileged "$AIRPRINT_UNPRIVILEGED" \
    --features    nesting=1,keyctl=1 \
    --onboot      1 \
    --start       0 \
    --password    "$AIRPRINT_ROOT_PW" \
    --tags        "airprint;cups;lxc" \
    --description "airprint-v2 — AirPrint/AirScan bridge for $AIRPRINT_PRINTER_MODEL"
  ok "LXC $AIRPRINT_CTID created"
else
  log "reusing existing LXC $AIRPRINT_CTID — skipping pct create"
fi
log "starting LXC $AIRPRINT_CTID"
if pct status "$AIRPRINT_CTID" 2>/dev/null | grep -q running; then
  log "container is already running — leaving it as-is"
else
  pct start "$AIRPRINT_CTID"
fi

# Wait for the container to come up and grab an IP / DNS.
log "waiting for container network…"
for _ in $(seq 1 30); do
  if pct exec "$AIRPRINT_CTID" -- sh -c 'getent hosts deb.debian.org >/dev/null 2>&1'; then
    break
  fi
  sleep 2
done
pct exec "$AIRPRINT_CTID" -- sh -c 'getent hosts deb.debian.org >/dev/null 2>&1' \
  || die "container has no working DNS / internet — check bridge/VLAN/firewall"
ok "container network is up"

# ---- ship the repo into the container -------------------------------------
log "installing repo into /opt/airprint-v2 inside the container"
pct exec "$AIRPRINT_CTID" -- sh -c '
  set -e
  export LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE=
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ca-certificates curl >/dev/null
'
if [[ -n "$AIRPRINT_LOCAL_CHECKOUT" ]]; then
  # Push from the local working tree (handy when iterating without a remote).
  # Exclude .git and any driver tarballs the user dropped in (the install
  # script can re-download / they're large), but keep drivers/ structure so
  # README.md / .gitkeep are present.
  log "pushing local working tree into container (/opt/airprint-v2)"
  pct exec "$AIRPRINT_CTID" -- sh -c 'rm -rf /opt/airprint-v2 && mkdir -p /opt/airprint-v2'
  tar -C "$AIRPRINT_LOCAL_CHECKOUT" \
      --exclude='./.git' \
      -cf - . \
    | pct exec "$AIRPRINT_CTID" -- tar -C /opt/airprint-v2 -xf -
else
  pct exec "$AIRPRINT_CTID" -- sh -c "
    set -e
    rm -rf /opt/airprint-v2
    git clone --depth 1 --branch '$AIRPRINT_REPO_BRANCH' '$AIRPRINT_REPO_URL' /opt/airprint-v2
  "
fi
ok "repo in place"

# ---- run the in-container installer ---------------------------------------
log "running /opt/airprint-v2/install.sh inside the container"
pct exec "$AIRPRINT_CTID" -- env \
  LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE= \
  AIRPRINT_PRINTER_IP="$AIRPRINT_PRINTER_IP" \
  AIRPRINT_PRINTER_MODEL="$AIRPRINT_PRINTER_MODEL" \
  AIRPRINT_QUEUE_NAME="$AIRPRINT_QUEUE_NAME" \
  AIRPRINT_NONINTERACTIVE=1 \
  bash /opt/airprint-v2/install.sh

# ---- final summary --------------------------------------------------------
ct_ip="$(pct exec "$AIRPRINT_CTID" -- sh -c "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1" || true)"
printf '\n%s== airprint-v2 install complete ==%s\n' "$C_BOLD" "$C_RESET"
printf '  Container ID  : %s\n'   "$AIRPRINT_CTID"
printf '  Hostname      : %s\n'   "$AIRPRINT_HOSTNAME"
printf '  Container IP  : %s\n'   "${ct_ip:-<unknown>}"
if (( AIRPRINT_REUSE_CT == 0 )); then
  printf '  Root password : %s\n' "$AIRPRINT_ROOT_PW"
else
  printf '  Root password : (unchanged — container was reused)\n'
fi
printf '  Queue name    : %s\n'   "$AIRPRINT_QUEUE_NAME"
printf '  IPP URL       : ipp://%s:631/printers/%s\n' "${ct_ip:-<host>}" "$AIRPRINT_QUEUE_NAME"
printf '  CUPS web UI   : http://%s:631/\n' "${ct_ip:-<host>}"
printf '  Scan share    : \\\\%s\\scans  (guest-writable, see Samba notes)\n' "${ct_ip:-<host>}"
printf '\nThe printer should now appear on iOS, macOS, and Windows 11 via Bonjour.\n'
printf 'Run the smoke test inside the container to verify everything end-to-end:\n'
printf '  pct enter %s\n' "$AIRPRINT_CTID"
printf '  /opt/airprint-v2/scripts/smoke-test.sh\n\n'
