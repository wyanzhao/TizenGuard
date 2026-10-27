# Agent Instructions (`TizenGuard`)

## Purpose
This repository contains the clean, public source for **TizenGuard** (`TizenGuard` / `TizenGuard.App` / `TizenGuard.Service`), an owner-controlled boot-policy service, telemetry/TV Plus debloater, and UI fluency optimizer for Samsung Tizen TVs.

## Hard Invariants
1. **No Secrets or Personal IPs**: Never commit `.p12`, `.pwd`, `.key`, `.pem`, DUIDs, serial numbers, personal LAN IPs, or machine-specific paths to this repository.
2. **10-Character Tizen Package ID**: Tizen `.wgt` packages require a 10-character alphanumeric package ID. Keep `package="TizenGuard"` (`TizenGuard.App` and `TizenGuard.Service`) consistent across `widget/config.xml`, `policies/boot-policy.sh`, `widget/service/check-policy.sh`, and `tools/provision-on-tv.sh`.
3. **SHA-256 Policy & Client Certificate Pinning**: `widget/service/main.js` and `widget/service/policy.js` must always verify `policy_sha256` before executing `/opt/usr/share/tizenguard/boot-policy.sh` and must verify `client_sha256` on every mTLS request. Never add a generic command execution endpoint.
4. **SQLite Lock Contention**: Any `sqlite3` invocation against `/opt/dbspace/.pkgmgr_parser.db` or `/opt/dbspace/.webappservice.db` during the post-boot window must set `.timeout 15000` (or `-cmd '.timeout 15000'`) so concurrent reads/writes from `amd` or `pkgmgr_server` never cause transient `Error: database is locked` failures.
5. **Service-Stopped Config Updates**: Whenever updating `/opt/usr/home/owner/apps_rw/TizenGuard/data/config.json` on the TV, stop `TizenGuard.Service` first (`kill -9 $(pgrep -f 'TizenGuard\.Service')`) so in-memory state cannot overwrite the updated file on disk.

## Build & Verification
Before committing any change, run:
```bash
python3 tools/build.py
```
This checks `bash -n` across all shell scripts, validates `widget/payload/manifest.json` SHA-256 digests, checks for forbidden internal tokens, stages `build/wgt/`, and runs `node --test test/*.test.cjs`.
