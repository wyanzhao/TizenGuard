#!/usr/bin/env bash
# Provision TizenGuard policy, .NET helpers, and mTLS credentials on a rooted Samsung Tizen TV.
set -euo pipefail

STAGE_DIR="${1:-/home/owner/share/tmp/sdk_tools/tizenguard-setup}"
APP_DATA_DIR="/opt/usr/home/owner/apps_rw/TizenGuard/data"
SHARE_DIR="/opt/usr/share/tizenguard"

printf System > /proc/self/attr/current

for required in \
  config.json \
  server-key.pem \
  server.pem \
  client.pem \
  boot-policy.sh \
  FeatureControl.dll \
  FeatureControl.deps.json \
  FeatureControl.runtimeconfig.json \
  SdkHostRecovery.dll \
  SdkHostRecovery.deps.json \
  SdkHostRecovery.runtimeconfig.json; do
  if ! test -f "$STAGE_DIR/$required" || test -L "$STAGE_DIR/$required"; then
    echo "ERROR: Missing or symlinked staged artifact: $STAGE_DIR/$required" >&2
    exit 1
  fi
done

actual_policy_sha="$(sha256sum "$STAGE_DIR/boot-policy.sh" | cut -d ' ' -f 1)"
configured_policy_sha="$(grep -o '"policy_sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]\{64\}"' "$STAGE_DIR/config.json" | grep -o '[0-9a-f]\{64\}')"
if test "$actual_policy_sha" != "$configured_policy_sha"; then
  echo "ERROR: policy_sha256 mismatch: config.json has $configured_policy_sha but boot-policy.sh is $actual_policy_sha" >&2
  exit 1
fi

sdk_host_ip="$(grep -o '"sdk_host_ip"[[:space:]]*:[[:space:]]*"[0-9.]\+"' "$STAGE_DIR/config.json" | grep -o '[0-9.]\+' | head -n 1)"
if test -z "$sdk_host_ip"; then
  echo "ERROR: sdk_host_ip missing in config.json" >&2
  exit 1
fi

# Stop any running TizenGuard.Service before writing config.json so in-memory state cannot overwrite disk.
kill -9 $(pgrep -f 'TizenGuard\.Service') 2>/dev/null || true

test ! -L "$SHARE_DIR"
mkdir -p "$SHARE_DIR/helper" "$SHARE_DIR/recovery" "$SHARE_DIR/backup"
chown -R 0:0 "$SHARE_DIR"
chmod 700 "$SHARE_DIR" "$SHARE_DIR/helper" "$SHARE_DIR/recovery" "$SHARE_DIR/backup"

# Preserve original SQLite databases and web app config.xml before the first policy run.
if ! test -f "$SHARE_DIR/backup/pkgmgr.before.db"; then
  cp -a /opt/dbspace/.pkgmgr_parser.db "$SHARE_DIR/backup/pkgmgr.before.db"
fi
if ! test -f "$SHARE_DIR/backup/webappservice.before.db"; then
  cp -a /opt/dbspace/.webappservice.db "$SHARE_DIR/backup/webappservice.before.db"
fi
for pkg in 30IKH0OX8U aQjWjLsPaO ZODRT12q2l; do
  if test -f "/opt/usr/apps/$pkg/res/config.xml" && ! test -f "$SHARE_DIR/backup/$pkg-config.xml.bak"; then
    cp -a "/opt/usr/apps/$pkg/res/config.xml" "$SHARE_DIR/backup/$pkg-config.xml.bak"
  fi
done

install -m 600 -o 0 -g 0 "$STAGE_DIR/boot-policy.sh" "$SHARE_DIR/boot-policy.sh"
chsmack -a System "$SHARE_DIR/boot-policy.sh"

for f in FeatureControl.dll FeatureControl.deps.json FeatureControl.runtimeconfig.json; do
  install -m 600 -o 0 -g 0 "$STAGE_DIR/$f" "$SHARE_DIR/helper/$f"
  chsmack -a System "$SHARE_DIR/helper/$f"
done

for f in SdkHostRecovery.dll SdkHostRecovery.deps.json SdkHostRecovery.runtimeconfig.json; do
  install -m 600 -o 0 -g 0 "$STAGE_DIR/$f" "$SHARE_DIR/recovery/$f"
  chsmack -a System "$SHARE_DIR/recovery/$f"
done

test ! -L "$APP_DATA_DIR"
mkdir -p "$APP_DATA_DIR"
chown 5001:100 "$APP_DATA_DIR"
chmod 700 "$APP_DATA_DIR"
chsmack -a User::Pkg::TizenGuard "$APP_DATA_DIR"

for cred in config.json server-key.pem server.pem client.pem; do
  rm -f "$APP_DATA_DIR/$cred"
  install -m 600 -o 5001 -g 100 "$STAGE_DIR/$cred" "$APP_DATA_DIR/$cred"
  chsmack -a User::Pkg::TizenGuard "$APP_DATA_DIR/$cred"
done

# Point SDB developer IP from sdk_host_ip (or 127.0.0.1) to 127.0.0.1 so TizenGuard.Service can self-connect on boot.
/usr/bin/dotnet "$SHARE_DIR/recovery/SdkHostRecovery.dll" set "$sdk_host_ip" 127.0.0.1 0

app_launcher -u 5001 -s TizenGuard.Service
echo "TIZENGUARD_PROVISIONED policy_sha256=$actual_policy_sha"
