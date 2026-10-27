# TizenGuard

**TizenGuard** is an owner-controlled boot-policy service, privacy/telemetry debloater, and UI fluency optimizer for Samsung Tizen TVs (tested on QN90A / Tizen 6.0 `T-NKM2AKUC-2310.0`).

It runs as an on-boot Tizen background service (`TizenGuard.Service` inside package `TizenGuard`) that:
1. Connects to the TV's local SDB daemon over loopback (`127.0.0.1:26101`) during the bounded post-boot window (`180s..600s` uptime).
2. Verifies the exact firmware version (`/etc/prd_info.ini`) and the SHA-256 digest of `/opt/usr/share/tizenguard/boot-policy.sh` before executing a single line of policy.
3. Disables **Samsung TV Plus**, ACR/telemetry daemons, ad tiles, voice/ambient background tasks, and redundant web/native services while keeping core streaming and HDMI gaming workflows intact (`TizenTube`, `Netflix`, `Apple TV`, `HBO/Max`, and `HDMI` game consoles).
4. Optimizes UI smoothness and zRAM/swap behavior by stopping `reclaimd` swap-thrashing, tuning `vm.swappiness=5`, protecting the Home Launcher (`DN_sung.tv.csfs`) and Enlightenment compositor (`enlightenment`) with `oom_score_adj = -900` and `renice -n -10`, and running `tizenguard-ui-guardian.service` to keep UI and media threads (`cobalt_launcher`, `GIBBON_MAIN`, `aria-engine`, `tv-viewer`, `menu`) in the root CPU cgroup (`/sys/fs/cgroup/cpu/tasks`).
5. Automatically closes its temporary root session once `uptime >= 600s` and exposes a pinned mutual-TLS (`mTLS`) owner maintenance API on port `28443` with zero generic command-execution endpoints.

---

## Key Features & Measured Results (Samsung QN90A, 1.8 GB RAM + 904 MB zRAM)

| Metric | Pre-Fluency Baseline | With TizenGuard | Change |
| :--- | :--- | :--- | :--- |
| **`SwapUsed` (`zram0`, `925,828 kB` total)** | `395,888 kB` (~386.6 MB used) | **`12,496 kB` (~12.2 MB used)** | **-96.8% (-383.4 MB swap freed)** |
| **`SwapFree`** | `529,940 kB` (~517.5 MB free) | **`913,332 kB` (~891.9 MB free)** | **+383.4 MB free zRAM** |
| **`MemAvailable` (with all 3 media runtimes loaded)** | `970,860 kB` (idle) | **`815,964 kB` (~796.8 MB free)** | **Zero swap thrash under full media load** |
| **Home Launcher (`DN_sung.tv.csfs`) RSS & Priority** | `182,708 kB` RSS, `nice 0`, `/Booster` cgroup | **`120,444 kB` RSS, `nice -10`, `oom_score_adj -900`, `0 kB` VmSwap** | **-62.3 MB RSS, zero cold-swap stutter** |
| **Samsung TV Plus** | Active + auto-re-enabled by Smart Hub | **Permanently blocked (3-layer defense)** | **0 processes / 0 tiles** |

---

## Repository Layout

- [`widget/`](widget) — Unsigned Tizen widget (`TizenGuard`, `TizenGuard.App`, `TizenGuard.Service`):
  - [`widget/config.xml`](widget/config.xml) — Tizen 6.0 package manifest (`TizenGuard`).
  - [`widget/service/main.js`](widget/service/main.js) — Bounded `[180s..600s]` boot state machine and pinned mTLS server (`/v1/status`, `/v1/enable`, `/v1/apply`, `/v1/disable`, `/v1/restore-sdk`, `/v1/reboot`).
  - [`widget/service/policy.js`](widget/service/policy.js) — Config schema validation, SHA-256 preflight guard generator, and replay-safe run journal.
  - [`widget/service/agent.js`](widget/service/agent.js) — Loopback SDB + archive-root session manager.
  - [`widget/service/check-policy.sh`](widget/service/check-policy.sh) — Read-only post-boot verification script (returns `exit 3` on transient post-boot drift so `main.js` triggers one automatic repair pass).
- [`policies/`](policies) — Root policy and optional app restoration scripts:
  - [`policies/boot-policy.sh`](policies/boot-policy.sh) — Idempotent root policy script verified by SHA-256 before execution.
  - [`policies/restore-optional-app.sh`](policies/restore-optional-app.sh) — Re-enables optional apps from local backups and DB snapshots.
- [`helpers/`](helpers) — C# (`.NET Core 3.1`) native P/Invoke helpers for Tizen `libfconfig.so` and `libvconf.so.0`:
  - [`helpers/FeatureControl/Program.cs`](helpers/FeatureControl/Program.cs) — Sets/verifies/restores 14 boolean + 1 integer `fconfig` keys (`com.samsung/featureconf/product.tvplus_support`, `uifw.support_animation`, `eden.hide_animation_support`, `broswer_preloading`, etc.) via `libfconfig.so`.
  - [`helpers/SdkHostRecovery/Program.cs`](helpers/SdkHostRecovery/Program.cs) — Switches `db/sdk/develop/ip` between `127.0.0.1` (loopback self-boot mode) and the owner's workstation IP (`/v1/restore-sdk`) via `libvconf.so.0`.
  - [`helpers/ArchiveRoot/`](helpers/ArchiveRoot) — Source for the `SamsungTvArchiveRoot` and `SamsungTvRootAgent` payload assemblies.
- [`tools/`](tools) — Build, certificate enrollment, provisioning, CLI, and rollback scripts:
  - [`tools/build.py`](tools/build.py) — Validates shell syntax, payload SHA-256 manifests, forbidden tokens, stages `build/wgt/`, and runs the unit test suite.
  - [`tools/generate-certs.py`](tools/generate-certs.py) — Generates server/client mTLS PEM certificates and a pinned `config.json`.
  - [`tools/provision-on-tv.sh`](tools/provision-on-tv.sh) — Installs `/opt/usr/share/tizenguard/boot-policy.sh`, helpers, backups, and `/opt/usr/home/owner/apps_rw/TizenGuard/data/config.json`.
  - [`tools/tizenguard-cli.py`](tools/tizenguard-cli.py) — Owner mTLS CLI (`status`, `enable`, `apply`, `disable`, `restore-sdk`, `reboot`).
  - [`tools/rollback.py`](tools/rollback.py) — Outputs the full root rollback script restoring stock `fconfig`, `pkgcmd -A` runtime cache, SQLite tables, and kernel settings.
- [`test/`](test) — Automated `node --test` suites covering mTLS auth, boot window state transitions, policy guards, and SQLite triggers.

---

## Verification & Build

Run the complete verification and staging pipeline locally:

```bash
python3 tools/build.py
```

### Enrolling Owner Certificates & Provisioning

1. Generate your private mTLS bundle and `config.json` (never commit generated certificates to git):
   ```bash
   python3 tools/generate-certs.py \
     --output-dir ./local-creds \
     --tv-ip <TV_LAN_IP> \
     --sdk-host-ip <WORKSTATION_LAN_IP>
   ```
2. Sign and install `build/wgt/` with your Samsung Tizen developer certificate (`tizen package -t wgt -s <profile> -- build/wgt && sdb install TizenGuard.wgt`).
3. Stage `./local-creds/*`, `policies/boot-policy.sh`, and `helpers/dist/*/*.{dll,deps.json,runtimeconfig.json}` to `/home/owner/share/tmp/sdk_tools/tizenguard-setup` on the TV and run [`tools/provision-on-tv.sh`](tools/provision-on-tv.sh) in a root shell.
4. Query service status over mTLS at any time:
   ```bash
   python3 tools/tizenguard-cli.py status --host <TV_LAN_IP> --cert-dir ./local-creds
   ```

---

## License

Released under the [MIT License](LICENSE).
