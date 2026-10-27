#!/usr/bin/env python3
"""Generate or execute the complete on-TV rollback script for TizenGuard."""

from __future__ import annotations

import argparse
import sys

ROLLBACK_SH = r"""set -euo pipefail
printf System > /proc/self/attr/current

SHARE_DIR="/opt/usr/share/tizenguard"

# 1. Stop TizenGuard.Service and UI guardian daemon.
kill -9 $(pgrep -f 'TizenGuard\.Service') 2>/dev/null || true
systemctl stop tizenguard-ui-guardian.service 2>/dev/null || true
rm -f /run/systemd/system/tizenguard-ui-guardian.service \
      /run/tizenguard/tizenguard-ui-guardian.service.new \
      /run/tizenguard/ui-guardian.sh

# 2. Restore all 14 boolean + 1 integer fconfig keys and remove animation disable marker.
if test -f "$SHARE_DIR/helper/FeatureControl.dll"; then
  /usr/bin/dotnet "$SHARE_DIR/helper/FeatureControl.dll" restore
fi
rm -f /opt/usr/home/owner/share/animation

# 3. Restore backed-up web app config.xml files.
for pkg in 30IKH0OX8U aQjWjLsPaO ZODRT12q2l; do
  if test -f "$SHARE_DIR/backup/$pkg-config.xml.bak"; then
    cp -a "$SHARE_DIR/backup/$pkg-config.xml.bak" "/opt/usr/apps/$pkg/res/config.xml"
  fi
done

# 4. Remove bind-mounts and unmask transient systemd masks.
for mnt in \
  /opt/usr/apps/TizenGuard/res/wgt/service/check-policy.sh \
  /etc/reclaimd/black_list \
  /etc/resourced/memory.conf \
  /etc/resourced/cpu.conf \
  /usr/apps/boot-helper-dyboost-tv/res/dybrules.conf; do
  umount "$mnt" 2>/dev/null || true
done

for link in /run/systemd/system/*; do
  if test -L "$link" && test "$(readlink "$link")" = /dev/null; then
    rm -f "$link"
  fi
done
systemctl daemon-reload
systemctl start reclaimd.service 2>/dev/null || true

# 5. Re-activate apps in AMD's in-memory cache via pkgcmd -A while package_app_info_for_uid.is_disabled='true' is present.
bg_sql="'com.samsung.tizen.smartthings-client','com.samsung.tizen.smartthings-thing','com.samsung.tv.mde-framework','com.samsung.tv.device-assistant-service','com.samsung.tv.device-assistant-viewer-app','NRi6kdBYJ0.AirPlayWebApp','com.samsung.tv.airplay-app','com.samsung.tv.airplay-service','com.samsung.tv.tvplus','com.samsung.tv.tvPlusDeeplinker','com.samsung.tv.slive-daemon','org.tizen.bms-service','org.tizen.primevideo','org.tizen.primevideo-dummy','org.tizen.primevideo_companionapp','30IKH0OX8U.TestBGService','30IKH0OX8U.cwservice','30IKH0OX8U.tilesservice','org.tizen.tts-engine-vd-ATSC','org.tizen.tts-engine-vd-ATSC-sr','org.tizen.tts-engine-vd-ATSC-noti','org.tizen.tts-engine-vd-ATSC-interrupt','org.tizen.register-device-ux','org.tizen.easysetup-daemon','com.samsung.tv.sboard-app'"
sqlite3 -bail -cmd '.timeout 15000' /opt/dbspace/.pkgmgr_parser.db "BEGIN IMMEDIATE; DROP TRIGGER IF EXISTS tizenguard_tvplus_app_disabled; DROP TRIGGER IF EXISTS tizenguard_tvplus_package_disabled; UPDATE package_info SET package_disable='false' WHERE package IN (SELECT package FROM package_app_info WHERE app_id IN ($bg_sql)); UPDATE package_app_info SET app_disable='false' WHERE app_id IN ($bg_sql); INSERT OR REPLACE INTO package_app_info_for_uid (app_id,uid,is_disabled,is_splash_screen_enabled) SELECT app_id,5001,'true','true' FROM package_app_info WHERE app_id IN ($bg_sql); COMMIT;"
systemd-run --unit="tizenguard-rollback-activate-$(date +%s)" -p Type=oneshot -p User=5001 -p Group=100 -p SmackProcessLabel=System /bin/bash -c 'for a in com.samsung.tizen.smartthings-client com.samsung.tizen.smartthings-thing com.samsung.tv.mde-framework com.samsung.tv.device-assistant-service com.samsung.tv.device-assistant-viewer-app NRi6kdBYJ0.AirPlayWebApp com.samsung.tv.airplay-app com.samsung.tv.airplay-service com.samsung.tv.tvplus com.samsung.tv.tvPlusDeeplinker com.samsung.tv.slive-daemon org.tizen.bms-service org.tizen.primevideo org.tizen.primevideo-dummy org.tizen.primevideo_companionapp 30IKH0OX8U.TestBGService 30IKH0OX8U.cwservice 30IKH0OX8U.tilesservice org.tizen.tts-engine-vd-ATSC org.tizen.tts-engine-vd-ATSC-sr org.tizen.tts-engine-vd-ATSC-noti org.tizen.tts-engine-vd-ATSC-interrupt org.tizen.register-device-ux org.tizen.easysetup-daemon com.samsung.tv.sboard-app; do /usr/bin/pkgcmd -A -t app -n "$a" --global --uid 5001 || true; done' >/dev/null 2>&1 || true
sleep 3

# 6. Restore SQLite databases from pre-provision backup if available.
if test -f "$SHARE_DIR/backup/pkgmgr.before.db"; then
  sqlite3 -bail /opt/dbspace/.pkgmgr_parser.db <<'SQL'
.timeout 15000
ATTACH DATABASE '/opt/usr/share/tizenguard/backup/pkgmgr.before.db' AS old;
BEGIN IMMEDIATE;
DROP TRIGGER IF EXISTS tizenguard_tvplus_app_disabled;
DROP TRIGGER IF EXISTS tizenguard_tvplus_package_disabled;
UPDATE package_info SET
  package_disable=(SELECT package_disable FROM old.package_info o WHERE o.package=package_info.package),
  package_nodisplay=(SELECT package_nodisplay FROM old.package_info o WHERE o.package=package_info.package)
 WHERE package IN (SELECT package FROM old.package_info);
UPDATE package_app_info SET
  app_disable=(SELECT app_disable FROM old.package_app_info o WHERE o.app_id=package_app_info.app_id),
  app_nodisplay=(SELECT app_nodisplay FROM old.package_app_info o WHERE o.app_id=package_app_info.app_id),
  app_onboot=(SELECT app_onboot FROM old.package_app_info o WHERE o.app_id=package_app_info.app_id),
  app_autorestart=(SELECT app_autorestart FROM old.package_app_info o WHERE o.app_id=package_app_info.app_id),
  app_preload=(SELECT app_preload FROM old.package_app_info o WHERE o.app_id=package_app_info.app_id)
 WHERE app_id IN (SELECT app_id FROM old.package_app_info);
DELETE FROM package_app_info_for_uid WHERE uid=5001;
INSERT OR REPLACE INTO package_app_info_for_uid SELECT * FROM old.package_app_info_for_uid WHERE uid=5001;
DELETE FROM package_app_app_metadata WHERE app_id IN (SELECT DISTINCT app_id FROM old.package_app_app_metadata);
INSERT INTO package_app_app_metadata SELECT * FROM old.package_app_app_metadata;
COMMIT;
DETACH DATABASE old;
pragma quick_check;
SQL
fi

if test -f "$SHARE_DIR/backup/webappservice.before.db"; then
  sqlite3 -bail /opt/dbspace/.webappservice.db <<'SQL'
.timeout 15000
ATTACH DATABASE '/opt/usr/share/tizenguard/backup/webappservice.before.db' AS old;
BEGIN IMMEDIATE;
UPDATE widgetinfo SET
  is_hidden=(SELECT is_hidden FROM old.widgetinfo o WHERE o.id=widgetinfo.id),
  is_display=(SELECT is_display FROM old.widgetinfo o WHERE o.id=widgetinfo.id),
  is_app_available=(SELECT is_app_available FROM old.widgetinfo o WHERE o.id=widgetinfo.id),
  install_state=(SELECT install_state FROM old.widgetinfo o WHERE o.id=widgetinfo.id)
 WHERE id IN (SELECT id FROM old.widgetinfo);
COMMIT;
DETACH DATABASE old;
pragma quick_check;
SQL
fi

# 7. Restore default kernel CPU, block I/O, and VM parameters.
for c in /sys/devices/system/cpu/cpu[0-3]/cpufreq; do
  echo 100000 > "$c/scaling_min_freq" 2>/dev/null || true
  echo 1700000 > "$c/scaling_max_freq" 2>/dev/null || true
done
if test -d /sys/devices/system/cpu/cpufreq/interactive; then
  echo 99 > /sys/devices/system/cpu/cpufreq/interactive/go_hispeed_load 2>/dev/null || true
  echo 90 > /sys/devices/system/cpu/cpufreq/interactive/target_loads 2>/dev/null || true
  echo 30000 > /sys/devices/system/cpu/cpufreq/interactive/timer_rate 2>/dev/null || true
  echo 30000 > /sys/devices/system/cpu/cpufreq/interactive/min_sample_time 2>/dev/null || true
  echo 20000 > /sys/devices/system/cpu/cpufreq/interactive/above_hispeed_delay 2>/dev/null || true
  echo 0 > /sys/devices/system/cpu/cpufreq/interactive/io_is_busy 2>/dev/null || true
fi
echo cfq > /sys/block/mmcblk0/queue/scheduler 2>/dev/null || true
echo 128 > /sys/block/mmcblk0/queue/read_ahead_kb 2>/dev/null || true
echo 1 > /sys/block/mmcblk0/queue/rq_affinity 2>/dev/null || true
echo 128 > /sys/block/mmcblk0/queue/nr_requests 2>/dev/null || true
sysctl -w vm.swappiness=100 vm.vfs_cache_pressure=100 vm.dirty_background_ratio=10 vm.dirty_ratio=20 >/dev/null

echo "TIZENGUARD_ROLLBACK_COMPLETE"
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--print-script",
        action="store_true",
        help="Print the root shell rollback script to stdout",
    )
    args = parser.parse_args()
    if args.print_script or len(sys.argv) == 1:
        sys.stdout.write(ROLLBACK_SH)
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
