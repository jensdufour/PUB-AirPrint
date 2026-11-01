# AirPrint

AirPrint now lives in a single repository.

- This `main` branch is the recommended implementation.
- The legacy Docker/CUPS implementation remains available on [`legacy/docker-cups`](https://github.com/jensdufour/PUB-AirPrint/tree/legacy/docker-cups).
- The older community-scripts-based Proxmox flow remains available on [`legacy/proxmox-lxc`](https://github.com/jensdufour/PUB-AirPrint/tree/legacy/proxmox-lxc).

A one-shot Proxmox helper that turns a legacy network printer (originally
designed for the Canon **imageRUNNER 1133A**) into a modern **AirPrint /
IPP Everywhere** device — and, where possible, exposes scanning over
**AirScan / eSCL** with a Samba scan-to-folder fallback.

It builds an unprivileged Debian 12 LXC on Proxmox and configures
`CUPS + cups-filters + Avahi (reflector) + SANE + sane-airscan + Samba`,
then publishes the printer/scanner over Bonjour so iOS, macOS and Windows 11
clients discover it natively.

> Inspired by the [community-scripts.org](https://community-scripts.org/)
> one-liner UX, but self-contained (no external `build.func` dependency).

---

## Requirements

| | |
|---|---|
| Hypervisor | Proxmox VE 8.x or 9.x |
| Host shell | `root` on the Proxmox node |
| Network | LXC must be bridged onto the same VLAN as the printer (or have an mDNS reflector available) |
| Printer | Canon iR 1133A (or any device speaking LPR / port 9100; driver path may differ) |
| Internet | Required during install (apt + optional Canon driver download) |

---

## Install (one-liner)

Run this on the **Proxmox host shell** as `root`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jensdufour/PUB-AirPrint/main/airprint-v2.sh)"
```

Non-interactive (CI / re-runs):

```bash
AIRPRINT_NONINTERACTIVE=1 \
AIRPRINT_CTID=200 \
AIRPRINT_HOSTNAME=airprint \
AIRPRINT_BRIDGE=vmbr0 \
AIRPRINT_VLAN=10 \
AIRPRINT_IP=dhcp \
AIRPRINT_PRINTER_IP=192.168.10.50 \
AIRPRINT_PRINTER_MODEL="Canon iR1133A" \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jensdufour/PUB-AirPrint/main/airprint-v2.sh)"
```

---

## What it does

1. Validates you're on a Proxmox node with `pct` available.
2. Pulls the `debian-12-standard` LXC template (downloads if missing).
3. Creates an unprivileged LXC: 1 vCPU / 512 MB RAM / 4 GB disk (overridable).
4. Bridges it onto your chosen `vmbrX` (+ optional VLAN tag).
5. Inside the container, runs [install.sh](install.sh) which:
   - `apt`-installs CUPS, cups-filters, cups-ipp-utils, Avahi, SANE, sane-airscan, Samba, ghostscript.
   - Replaces `/etc/cups/cupsd.conf` (backing the original up to `…airprint-orig`) with one tuned for AirPrint + Bonjour + page logging + retry-on-drop.
   - Enables CUPS' SNMP supplies polling (`/etc/cups/snmp.conf`) so toner level and page counter surface on iOS / macOS.
   - Drops in the Avahi **reflector** config.
   - Adds the printer queue via `lpadmin`, then patches the generated PPD with `*cupsURF` / `*cupsIPPSupplies` / `*cupsSNMPSupplies` (only if missing) so iOS treats it as a fully-featured AirPrint device.
   - Tries to auto-detect the scanner with SANE; publishes via `sane-airscan` if found.
   - Configures a Samba share `scans/` as a reliable scan-to-folder fallback.
   - Installs a healthcheck cron + a `ufw` ruleset.
6. Prints the queue name, IPP URL, and scan-to-folder UNC path on success.

---

## Repo layout

```
AirPrint/
├── airprint-v2.sh             # Host entry point (one-liner target)
├── install.sh                 # Runs INSIDE the LXC
├── uninstall.sh               # Tear-down helper (in-container)
├── Makefile                   # `make lint` (shellcheck) before pushing
├── .github/workflows/lint.yml # CI: shellcheck
├── lib/
│   ├── common.sh              # logging / colors / error trap (sourced both sides)
│   └── host_prompts.sh        # interactive prompts (host side)
├── config/
│   ├── avahi-daemon.conf      # Reflector config
│   ├── cupsd.conf             # CUPS config (full file, replaces stock)
│   └── snmp.conf              # CUPS SNMP supplies polling
├── scripts/
│   ├── add-printer.sh         # Idempotent CUPS queue add (re-runnable)
│   ├── add-scanner.sh         # SANE + airscan setup
│   ├── add-scan-share.sh      # Samba scan-to-folder share
│   ├── canon-ufr2-install.sh  # Canon UFR II driver helper
│   ├── healthcheck.sh         # cron — verifies CUPS + Avahi + queue + Bonjour
│   └── smoke-test.sh          # End-to-end post-install verification
└── drivers/                   # Optional: drop Canon's tarball here
```

---

## Page reporting & iOS Dynamic Island

> **TL;DR — page-X-of-Y in iOS's Print Center / Dynamic Island works, _provided_ a real driver is in use.**

How the chain actually works:

1. The CUPS filter (UFR II's `pstoufr2cpca` or generic `gstoraster`) emits
   `PAGE: 3 1` lines to stderr while rasterising.
2. CUPS reads those lines and increments the `job-impressions-completed`
   IPP attribute on the running job.
3. iOS subscribes to `job-state-changed` + `job-progress` events when it
   submits the print job. It receives every increment as a push notification.
4. iOS's Print Center renders that as `"Page X of Y"`, and on iPhone 14 Pro
   and later it surfaces the same Live Activity in the **Dynamic Island**.

What we did to make this work:

- ✅ Use the Canon **UFR II** filter when available (best fidelity + page reporting).
- ✅ Fall back to **gstoraster** (Ghostscript) which also emits PAGE: lines.
- ✅ Tell CUPS to emit `job-progress` notifications by default (cupsd.conf).
- ✅ Patch the PPD with `*cupsURF` / `*cupsIPPSupplies` / `*cupsSNMPSupplies` so iOS sees this as a "real" AirPrint device with toner/paper status.
- ✅ Enable `/etc/cups/snmp.conf` so toner level + lifetime page counter populate on the print dialog.
- ✅ Enable `PageLogFormat` in cupsd.conf — `/var/log/cups/page_log` becomes a chronological audit trail of every page printed (user, queue, job, page, copies, billing, host, filename, media, sides).

What you can verify after install (inside the LXC):

```bash
/opt/airprint-v2/scripts/smoke-test.sh        # end-to-end: services, IPP, Bonjour, SMB, PPD hints
tail -f /var/log/cups/page_log                # live page-by-page log
ipptool -tv ipp://localhost:631/printers/Canon_iR1133A \
        /usr/share/cups/ipptool/get-printer-attributes.test
avahi-browse -rtp _ipp._tcp                   # Bonjour TXT records as iOS sees them
```

What this **doesn't** give you:

- The 1133A doesn't natively report ink/toner via SNMP for every consumable
  (some Canon iR models stub the supplies MIB). The page counter is reliable;
  toner level may show as "unknown" — that's the printer firmware, not us.
- Generic `sample.drv/generic.ppd` fallback (no real driver) gives basic
  printing but limited per-page progress. Drop the Canon UFR II tarball into
  `drivers/` to fix this — see [drivers/README.md](drivers/README.md).

---

## Driver story

The 1133A is **not** an IPP-Everywhere device — it speaks LPR and raw 9100,
and renders **UFR II** natively (PCL5e if the optional kit is fitted). The
installer handles three scenarios automatically:

| Scenario | Result |
|---|---|
| You drop Canon's UFR II tarball into `drivers/` (or set `CANON_UFR2_URL`) | UFR II PPD installed, full quality, accurate page reporting |
| Printer has the **PostScript** option board | Generic PS PPD, works out of the box |
| Neither | Falls back to **`drv:///sample.drv/generic.ppd`** + warns; basic printing only |

CUPS 2.4 (Debian 12) emits the right `URF` / `pdl` Bonjour TXT records as
long as the PPD declares URF support. The installer patches the PPD with a
conservative-but-valid URF declaration if the key is missing — without it
iOS sometimes greys out the **Print** button.

---

## Scanning story (honest version)

The iR 1133A does **not** speak eSCL natively, and Canon's Linux scan
driver coverage for this model is poor. The installer tries, in order:

1. `sane-airscan` auto-discovery (works only if the printer ever exposes
   eSCL — most 1133A firmwares don't).
2. SANE `pixma` backend (rare on iR series — included for completeness).
3. **Samba scan-to-folder fallback** — always set up. You configure the
   printer's Send-to-SMB feature to push scans into the share. This is the
   path that actually works reliably; everything else is best-effort.

---

## Re-running individual pieces

All helper scripts under `scripts/` are idempotent and can be re-run inside
the LXC:

```bash
pct enter <CTID>
/opt/airprint-v2/scripts/add-printer.sh
/opt/airprint-v2/scripts/add-scanner.sh
/opt/airprint-v2/scripts/add-scan-share.sh
/opt/airprint-v2/scripts/healthcheck.sh
/opt/airprint-v2/scripts/smoke-test.sh   # ← end-to-end verification
```

You can also re-run the host bootstrap with the same `AIRPRINT_CTID`; it
will detect the existing container and just re-run `install.sh` inside it.

---

## Local development

Before pushing changes, lint locally:

```bash
make lint     # shellcheck, severity=style
```

CI (`.github/workflows/lint.yml`) runs the same shellcheck on every push
and PR.

---

## Uninstall

Inside the container:

```bash
/opt/airprint-v2/uninstall.sh
```

Or simply destroy the LXC from Proxmox: `pct stop <CTID> && pct destroy <CTID>`.

---

## License

MIT — see [LICENSE](LICENSE).
