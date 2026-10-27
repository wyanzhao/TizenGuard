# TizenGuard Architecture & Security Model

## 1. Threat & Execution Model
Samsung Tizen 6.0 TVs reset transient process states, `systemd` runtime masks (`/run/systemd/system`), and Smart Hub app flags (`com.samsung.tv.tvplus`) across reboots and cloud syncs. At the same time, leaving an unauthenticated root agent or LAN SDB daemon open permanently exposes the TV on the local network.

**TizenGuard** solves both problems:
- **Loopback-Only SDB (`db/sdk/develop/ip = 127.0.0.1`)**: During normal operation, the TV's `sdbd` only accepts connections from `127.0.0.1`. External LAN hosts cannot connect to port `26101`.
- **Bounded Boot Window (`180s..600s` uptime)**: `TizenGuard.Service` (`app_onboot='true'`, `app_autorestart='true'`) waits until `/proc/uptime` reaches `180s` (after Tizen's initial mount and `pkgmgr` storm settles), acquires a loopback archive-root session, verifies `/etc/prd_info.ini` and the SHA-256 hash of `/opt/usr/share/tizenguard/boot-policy.sh`, applies the policy once per `boot_id`, runs `check-policy.sh` to repair any late post-boot drift (`exit 3`), and **terminates the root session at `600s` uptime**.
- **Pinned mTLS Maintenance API (`:28443`)**: Every HTTPS request requires a client certificate whose DER SHA-256 digest matches `client_sha256` in `config.json`. Only six fixed endpoints exist (`GET /v1/status`, `POST /v1/enable`, `POST /v1/apply`, `POST /v1/disable`, `POST /v1/restore-sdk`, `POST /v1/reboot`).

## 2. Three-Layer Samsung TV Plus & Bloatware Defense
Simply running `pkgcmd -D` on Samsung TV Plus (`com.samsung.tv.tvplus`) is insufficient because Smart Hub (`com.samsung.tv.eden-service`) periodically executes SQL `UPDATE` statements on `/opt/dbspace/.pkgmgr_parser.db` to re-enable TV Plus. TizenGuard enforces a three-layer defense:
1. **Platform Feature Config (`fconfig`)**: `FeatureControl.dll` P/Invokes `libfconfig.so` (`fconfig_set_bool`, `fconfig_set_value_int`) to set `com.samsung/featureconf/product.tvplus_support = 0` alongside 13 other non-essential feature flags (`uifw.support_animation`, `eden.hide_animation_support`, `broswer_preloading`, etc.).
2. **SQLite `AFTER UPDATE` Triggers**: `tizenguard_tvplus_app_disabled` and `tizenguard_tvplus_package_disabled` on `/opt/dbspace/.pkgmgr_parser.db` intercept any `UPDATE` attempting to set `app_disable != 'true'` or `package_disable != 'true'` on `com.samsung.tv.tvplus`, `com.samsung.tv.tvPlusDeeplinker`, `com.samsung.tv.slive-daemon`, or `org.tizen.bms-service` and immediately force them back to disabled/hidden.
3. **Runtime `pkgcmd -D` Sync**: Synchronizes `amd`'s in-memory cache so running processes are terminated and prevented from launching.

## 3. UI Fluency & Memory Reclamation Architecture
On 1.8 GB RAM Tizen TVs (such as the QN90A with `925,828 kB` / ~904 MB `zram0`), Samsung's stock `reclaimd` aggressively swaps out the Home Launcher (`DN_sung.tv.csfs`) and `resourced` (`cpu.conf`) throttles backgrounded cgroups to `50` CPU shares, causing multi-second stutters when pressing the Home button.
- TizenGuard stops and masks `reclaimd.service`, lowers `vm.swappiness` from `100` to `5`, drains `zram0` swap back into RAM, and bind-mounts tuned `/etc/reclaimd/black_list`, `/etc/resourced/memory.conf`, `/etc/resourced/cpu.conf`, and `/usr/apps/boot-helper-dyboost-tv/res/dybrules.conf`.
- `tizenguard-ui-guardian.service` pins `enlightenment` (compositor) and `DN_sung.tv.csfs` (Home Launcher) to `oom_score_adj = -900` and `renice -n -10`, pins media/HDMI services (`cobalt_launcher`, `GIBBON_MAIN`, `aria-engine`, `aria-video`, `menu`, `tv-viewer`, `hdmicec-service`, `source-service`, `gamepad-service`) to `renice -n -6`, and migrates all their threads (`/proc/$pid/task/*`) to the root CPU cgroup (`/sys/fs/cgroup/cpu/tasks`).
