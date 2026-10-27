#!/usr/bin/env bash
# Restore a previously uninstalled Tizen optional app from a local backup archive and DB snapshots.
# Usage (as root on the TV):
#   PKG=com.samsung.tv.aria-video STORE_ID=3201807016597 ARCHIVE=/opt/usr/share/tizenguard/appletv/appletv-restore.tar.gz \
#   PKGMGR_SNAP=/opt/usr/share/tizenguard/backup/pkgmgr.before.db WAS_SNAP=/opt/usr/share/tizenguard/backup/webappservice.before.db \
#   /bin/bash < restore-optional-app.sh
set -eu
printf System > /proc/self/attr/current

PKG="${PKG:?PKG is required}"
STORE_ID="${STORE_ID:?STORE_ID is required}"
ARCHIVE="${ARCHIVE:?ARCHIVE is required}"
PKGMGR_SNAP="${PKGMGR_SNAP:?PKGMGR_SNAP is required}"
WAS_SNAP="${WAS_SNAP:?WAS_SNAP is required}"

test -f "$ARCHIVE" && test -f "$PKGMGR_SNAP" && test -f "$WAS_SNAP"

tar --same-owner -xzpf "$ARCHIVE" -C /

chsmack -a "User::Home" -t "/opt/usr/apps/$PKG" "/opt/usr/home/owner/apps_rw/$PKG"
for d in bin res shared; do
  if [ -d "/opt/usr/apps/$PKG/$d" ]; then
    chsmack -a "User::Pkg::${PKG}::RO" -t -r "/opt/usr/apps/$PKG/$d"
  fi
done
for d in cache data shared/trusted; do
  if [ -d "/opt/usr/home/owner/apps_rw/$PKG/$d" ]; then
    chsmack -a "User::Pkg::${PKG}" -t -r "/opt/usr/home/owner/apps_rw/$PKG/$d"
  fi
done
if [ -f "/opt/share/packages/$PKG.xml" ]; then
  chsmack -a "_" "/opt/share/packages/$PKG.xml"
fi

sqlite3 -bail /opt/dbspace/.pkgmgr_parser.db <<SQL
.timeout 15000
ATTACH DATABASE '$PKGMGR_SNAP' AS snap;
BEGIN IMMEDIATE;
INSERT OR REPLACE INTO main.package_info SELECT * FROM snap.package_info WHERE package='$PKG';
INSERT OR REPLACE INTO main.package_localized_info SELECT * FROM snap.package_localized_info WHERE package='$PKG';
DELETE FROM main.package_privilege_info WHERE package='$PKG';
INSERT INTO main.package_privilege_info SELECT * FROM snap.package_privilege_info WHERE package='$PKG';
INSERT OR REPLACE INTO main.package_update_info SELECT * FROM snap.package_update_info WHERE package='$PKG';
INSERT OR REPLACE INTO main.package_app_info SELECT * FROM snap.package_app_info WHERE package='$PKG';
INSERT OR REPLACE INTO main.package_app_localized_info SELECT * FROM snap.package_app_localized_info
  WHERE app_id IN (SELECT app_id FROM snap.package_app_info WHERE package='$PKG');
DELETE FROM main.package_app_app_metadata
  WHERE app_id IN (SELECT app_id FROM snap.package_app_info WHERE package='$PKG');
INSERT INTO main.package_app_app_metadata SELECT * FROM snap.package_app_app_metadata
  WHERE app_id IN (SELECT app_id FROM snap.package_app_info WHERE package='$PKG');
DELETE FROM main.package_plugin_info WHERE pkgid='$PKG';
INSERT INTO main.package_plugin_info SELECT * FROM snap.package_plugin_info WHERE pkgid='$PKG';
UPDATE main.package_info SET package_disable='false', package_nodisplay='false' WHERE package='$PKG';
UPDATE main.package_app_info SET app_disable='false', app_nodisplay='false', app_preload='false' WHERE package='$PKG';
INSERT OR IGNORE INTO main.package_app_info_for_uid (app_id, uid, is_disabled, is_splash_screen_enabled)
  SELECT app_id, 5001, 'true', 'true' FROM main.package_app_info WHERE package='$PKG';
COMMIT;
DETACH DATABASE snap;
SQL

sqlite3 -bail /opt/dbspace/.webappservice.db <<SQL
.timeout 15000
ATTACH DATABASE '$WAS_SNAP' AS snap;
BEGIN IMMEDIATE;
INSERT OR REPLACE INTO widgetinfo SELECT * FROM snap.widgetinfo WHERE id='$STORE_ID' OR pkgname='$PKG';
UPDATE widgetinfo SET is_hidden=0, is_display=1, is_app_available=1, install_state=3 WHERE id='$STORE_ID' OR pkgname='$PKG';
UPDATE WASConfigTable SET value=REPLACE(REPLACE(value, ',$STORE_ID', ''), '$STORE_ID,', '')
  WHERE name='RESERVED_19' AND value LIKE '%$STORE_ID%';
COMMIT;
DETACH DATABASE snap;
SQL

systemd-run --quiet --wait --pipe \
  -p Type=oneshot -p User=5001 -p Group=100 -p SmackProcessLabel=System \
  --setenv=HOME=/opt/usr/home/owner \
  --setenv=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/5001/dbus/user_bus_socket \
  /bin/sh -lc "/usr/bin/pkgcmd -A -t app -n '$PKG' --global --uid 5001 >/dev/null 2>&1 || true"

sqlite3 -bail /opt/dbspace/.pkgmgr_parser.db <<SQL
.timeout 15000
DELETE FROM package_app_info_for_uid WHERE app_id IN (SELECT app_id FROM package_app_info WHERE package='$PKG');
SQL

echo "RESTORED:$PKG"
