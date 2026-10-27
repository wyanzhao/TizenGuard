#!/usr/bin/env bash
# TizenGuard Boot Policy — UI Fluency, Memory Reclamation & Privacy Debloat Suite
# Retains ONLY core functions:
#   - TizenTube (TizenTubeS.TizenTube + TizenTubeS.StandaloneService + com.samsung.tv.cobalt-yt)
#   - Netflix (org.tizen.netflix-app)
#   - Apple TV (com.samsung.tv.aria-video)
#   - HBO / Max (exempted from all disable/hide rules; Store available on demand)
#   - HDMI / Game Console Connectivity (hdmicec-service, source-service, gamepad-service, tv-viewer, menu, gamebar)
set -eu
printf System > /proc/self/attr/current

BASE=/opt/usr/share/tizenguard
RUN=/run/tizenguard
mkdir -p "$RUN" "$BASE/backup"

# 1. Disable non-essential fconfig feature flags (animations, ads, multiview preview, TV Plus, voice, AirPlay, HbbTV).
if test -f "$BASE/helper/FeatureControl.dll"; then
  /usr/bin/dotnet "$BASE/helper/FeatureControl.dll" disable
fi

# Enforce persistent systemd negative ConditionPathExists markers for TV Plus, analytics, voice, and health.
mkdir -p /opt/usr/share/systemd/system
touch /opt/usr/share/systemd/system/bms \
      /opt/usr/share/systemd/system/slive-provider-daemon \
      /opt/usr/share/systemd/system/canalysis-daemon \
      /opt/usr/share/systemd/system/samsunghealth-service-tv \
      /opt/usr/share/systemd/system/com.samsung.tv.ondevice-voice

# 2. Self-heal Apple TV (com.samsung.tv.aria-video) from local backup if absent, and unmask HDMI gamepad service.
rm -f /run/systemd/system/gamepad-service.service
PERM_APPLETV="$BASE/appletv"
if test ! -d /opt/usr/apps/com.samsung.tv.aria-video && test -f "$PERM_APPLETV/appletv-restore.tar.gz"; then
  tar --same-owner -xzpf "$PERM_APPLETV/appletv-restore.tar.gz" -C /
  if test -d "$PERM_APPLETV/icons"; then
    mkdir -p /opt/share/webappservice/apps_icon/all/3201807016597
    cp -f "$PERM_APPLETV/icons/"*.png /opt/share/webappservice/apps_icon/all/3201807016597/
    chown -R 5001:users /opt/share/webappservice/apps_icon/all/3201807016597
    chmod 777 /opt/share/webappservice/apps_icon/all/3201807016597
    chmod 644 /opt/share/webappservice/apps_icon/all/3201807016597/*.png
  fi
  cp -f /opt/usr/apps/com.samsung.tv.aria-video/tizen-manifest.xml /opt/share/packages/com.samsung.tv.aria-video.xml
  chmod 644 /opt/share/packages/com.samsung.tv.aria-video.xml
  if test -f /opt/share/signatures/org.tizen.primevideo.txt && test ! -f /opt/share/signatures/com.samsung.tv.aria-video.txt; then
    cp -f /opt/share/signatures/org.tizen.primevideo.txt /opt/share/signatures/com.samsung.tv.aria-video.txt
    chmod 644 /opt/share/signatures/com.samsung.tv.aria-video.txt
  fi
  /usr/bin/security-manager-cmd --manage-apps=add \
    --app=com.samsung.tv.aria-video \
    --pkg=com.samsung.tv.aria-video \
    --uid=201 \
    --tizen=4.0 \
    --install-type=global \
    --pkg-privilege-level=partner \
    --pkg-type=core \
    --privilege=http://tizen.org/privilege/appdir.shareddata \
    --privilege=http://tizen.org/privilege/network.get \
    --privilege=http://tizen.org/privilege/internal/buxton/network.get \
    --privilege=http://tizen.org/privilege/internal/default/partner \
    --privilege=http://tizen.org/privilege/internal/default/public >/dev/null 2>&1 || true
  /usr/bin/security-manager-cmd --manage-apps=add \
    --app=com.samsung.tv.aria-dummy \
    --pkg=com.samsung.tv.aria-video \
    --uid=201 \
    --tizen=4.0 \
    --install-type=global \
    --pkg-privilege-level=partner \
    --pkg-type=core >/dev/null 2>&1 || true
  chsmack -a "User::Home" -t /opt/usr/apps/com.samsung.tv.aria-video
  chsmack -r -a "User::Pkg::com.samsung.tv.aria-video::RO" /opt/usr/apps/com.samsung.tv.aria-video/bin /opt/usr/apps/com.samsung.tv.aria-video/res /opt/usr/apps/com.samsung.tv.aria-video/shared
  chsmack -t /opt/usr/apps/com.samsung.tv.aria-video/bin /opt/usr/apps/com.samsung.tv.aria-video/res /opt/usr/apps/com.samsung.tv.aria-video/shared
  chsmack -a "User::Home" /opt/usr/apps/com.samsung.tv.aria-video/author-signature.xml /opt/usr/apps/com.samsung.tv.aria-video/tizen-manifest.xml
  chsmack -a "User::Home" -t /opt/usr/home/owner/apps_rw/com.samsung.tv.aria-video /opt/usr/home/owner/apps_rw/com.samsung.tv.aria-video/shared
  chsmack -r -a "User::Pkg::com.samsung.tv.aria-video" /opt/usr/home/owner/apps_rw/com.samsung.tv.aria-video/cache /opt/usr/home/owner/apps_rw/com.samsung.tv.aria-video/data /opt/usr/home/owner/apps_rw/com.samsung.tv.aria-video/shared/trusted
  chsmack -t /opt/usr/home/owner/apps_rw/com.samsung.tv.aria-video/cache /opt/usr/home/owner/apps_rw/com.samsung.tv.aria-video/data /opt/usr/home/owner/apps_rw/com.samsung.tv.aria-video/shared/trusted
fi
if test -f "$BASE/backup/pkgmgr.before.db" && test "$(sqlite3 -readonly -cmd '.timeout 15000' /opt/dbspace/.pkgmgr_parser.db "SELECT count(*) FROM package_info WHERE package='com.samsung.tv.aria-video';")" = 0; then
  sqlite3 -bail /opt/dbspace/.pkgmgr_parser.db <<'SQL'
.timeout 15000
ATTACH '/opt/usr/share/tizenguard/backup/pkgmgr.before.db' AS b3;
BEGIN IMMEDIATE;
INSERT OR REPLACE INTO main.package_info SELECT * FROM b3.package_info WHERE package='com.samsung.tv.aria-video';
INSERT OR REPLACE INTO main.package_localized_info SELECT * FROM b3.package_localized_info WHERE package='com.samsung.tv.aria-video';
DELETE FROM main.package_privilege_info WHERE package='com.samsung.tv.aria-video';
INSERT INTO main.package_privilege_info SELECT * FROM b3.package_privilege_info WHERE package='com.samsung.tv.aria-video';
INSERT OR REPLACE INTO main.package_update_info SELECT * FROM b3.package_update_info WHERE package='com.samsung.tv.aria-video';
INSERT OR REPLACE INTO main.package_app_info SELECT * FROM b3.package_app_info WHERE package='com.samsung.tv.aria-video';
INSERT OR REPLACE INTO main.package_app_localized_info SELECT * FROM b3.package_app_localized_info WHERE app_id IN ('com.samsung.tv.aria-video','com.samsung.tv.aria-dummy');
DELETE FROM main.package_app_app_metadata WHERE app_id IN ('com.samsung.tv.aria-video','com.samsung.tv.aria-dummy');
INSERT INTO main.package_app_app_metadata SELECT * FROM b3.package_app_app_metadata WHERE app_id IN ('com.samsung.tv.aria-video','com.samsung.tv.aria-dummy');
DELETE FROM main.package_plugin_info WHERE pkgid='com.samsung.tv.aria-video';
INSERT INTO main.package_plugin_info SELECT * FROM b3.package_plugin_info WHERE pkgid='com.samsung.tv.aria-video';
COMMIT;
DETACH b3;
SQL
fi
if test -f "$BASE/backup/webappservice.before.db" && test "$(sqlite3 -readonly -cmd '.timeout 15000' /opt/dbspace/.webappservice.db "SELECT count(*) FROM widgetinfo WHERE id='3201807016597';")" = 0; then
  sqlite3 -bail /opt/dbspace/.webappservice.db <<'SQL'
.timeout 15000
ATTACH '/opt/usr/share/tizenguard/backup/webappservice.before.db' AS w3;
BEGIN IMMEDIATE;
INSERT OR REPLACE INTO main.widgetinfo SELECT * FROM w3.widgetinfo WHERE id='3201807016597';
UPDATE main.WASConfigTable SET value=REPLACE(REPLACE(value, ',3201807016597', ''), '3201807016597,', '') WHERE name='RESERVED_19';
COMMIT;
DETACH w3;
SQL
fi

# Ensure retained core packages (TizenTube, Netflix, Apple TV, HDMI/GameBar, Menu, TV-Viewer, Apps Store & helpers) have package_disable/app_disable='false' before native pkgcmd -A activation.
sqlite3 -bail -cmd '.timeout 15000' /opt/dbspace/.pkgmgr_parser.db "BEGIN IMMEDIATE; UPDATE package_info SET package_disable='false',package_nodisplay='false' WHERE package IN ('TizenTubeS','org.tizen.netflix-app','com.samsung.tv.aria-video','com.samsung.tv.aria-engine','lib-ariafw-tv','com.samsung.tv.gamebar','org.tizen.menu','org.tizen.tv-viewer','org.tizen.ambientapp','com.samsung.tv.store','com.samsung.tv.coba.apps','org.tizen.content-tiles-provider','ContentServiceManager','com.samsung.tv.waapp-contents-provider','com.samsung.tv.cis-service-app','com.samsung.tv.cis-api-service-app','WykOS4t4F0','ZODRT12q2l','com.samsung.tv.sboard-app','com.samsung.hitcomp','com.samsung.tv.coba.privacy_app','com.samsung.ep.coba.hotel','com.samsung.tizen.samsung-cloud','com.samsung.tv.ghdaemon','com.samsung.tv.ContentsBrowser'); UPDATE package_app_info SET app_disable='false',app_nodisplay='false',app_preload='false' WHERE app_id IN ('com.samsung.tv.aria-video','com.samsung.tv.aria-dummy','com.samsung.tv.aria-engine','com.samsung.tv.gamebar'); UPDATE package_app_info SET app_disable='false',app_nodisplay='false' WHERE app_id IN ('com.samsung.tv.store','org.volt.apps','com.samsung.tv.coba.apps'); UPDATE package_app_info SET app_preload='true' WHERE app_id='com.samsung.tv.coba.apps'; UPDATE package_app_info SET app_disable='false' WHERE app_id IN ('TizenTubeS.TizenTube','TizenTubeS.StandaloneService','org.tizen.netflix-app','org.tizen.menu','org.tizen.tv-viewer','org.tizen.ambientapp','org.tizen.content-tiles-provider','ContentServiceManager','com.samsung.tv.waapp-contents-provider','com.samsung.tv.cis','com.samsung.tv.cis-api-service-app','WykOS4t4F0.cmsWebApp','ZODRT12q2l.WebAccountExtension','com.samsung.tv.sboard-app','com.samsung.hitcomp','com.samsung.tv.coba.privacychoice','com.samsung.ep.coba.hotel','com.samsung.tizen.samsung-cloud','com.samsung.tv.ghdaemon','com.samsung.tv.ContentsBrowser','com.samsung.tv.ContentsBrowserDetail'); DELETE FROM package_app_info_for_uid WHERE app_id IN ('com.samsung.tv.store','org.volt.apps','com.samsung.tv.coba.apps','org.tizen.content-tiles-provider','ContentServiceManager','com.samsung.tv.waapp-contents-provider','com.samsung.tv.cis','com.samsung.tv.cis-api-service-app','WykOS4t4F0.cmsWebApp','ZODRT12q2l.WebAccountExtension','com.samsung.tv.sboard-app','com.samsung.hitcomp','com.samsung.tv.coba.privacychoice','com.samsung.ep.coba.hotel','com.samsung.tizen.samsung-cloud','com.samsung.tv.ghdaemon','com.samsung.tv.ContentsBrowser','com.samsung.tv.ContentsBrowserDetail'); INSERT OR IGNORE INTO package_app_info_for_uid (app_id,uid,is_disabled,is_splash_screen_enabled) VALUES ('com.samsung.tv.aria-video',5001,'true','true'),('com.samsung.tv.aria-dummy',5001,'true','true'),('com.samsung.tv.gamebar',5001,'true','true'); COMMIT;"

# 3. Native per-owner deactivation/activation refreshes AMD in-memory cache for background/TVPlus/PrimeVideo/AriaBG/TTS/Setup and retained apps.
bg_sql="'com.samsung.tizen.smartthings-client','com.samsung.tizen.smartthings-thing','com.samsung.tv.mde-framework','com.samsung.tv.device-assistant-service','com.samsung.tv.device-assistant-viewer-app','NRi6kdBYJ0.AirPlayWebApp','com.samsung.tv.airplay-app','com.samsung.tv.airplay-service','com.samsung.tv.tvplus','com.samsung.tv.tvPlusDeeplinker','com.samsung.tv.slive-daemon','org.tizen.bms-service','org.tizen.primevideo','org.tizen.primevideo-dummy','org.tizen.primevideo_companionapp','30IKH0OX8U.TestBGService','30IKH0OX8U.cwservice','30IKH0OX8U.tilesservice','org.tizen.tts-engine-vd-ATSC','org.tizen.tts-engine-vd-ATSC-sr','org.tizen.tts-engine-vd-ATSC-noti','org.tizen.tts-engine-vd-ATSC-interrupt','org.tizen.register-device-ux','org.tizen.easysetup-daemon'"
sqlite3 -bail -cmd '.timeout 15000' /opt/dbspace/.pkgmgr_parser.db "BEGIN IMMEDIATE; DROP TRIGGER IF EXISTS tizenguard_tvplus_app_disabled; DROP TRIGGER IF EXISTS tizenguard_tvplus_package_disabled; UPDATE package_info SET package_disable='false' WHERE package IN (SELECT package FROM package_app_info WHERE app_id IN ($bg_sql)); UPDATE package_app_info SET app_disable='false',app_onboot='false',app_autorestart='false',app_preload='false' WHERE app_id IN ($bg_sql); UPDATE package_app_info_for_uid SET is_disabled='false' WHERE uid=5001 AND app_id IN ($bg_sql); COMMIT;"
log="$RUN/background-deactivate.log"
: > "$log"; chown 5001:100 "$log"; chmod 600 "$log"; chsmack -a System "$log"
unit="tizenguard-native-disable-$(date +%s)"
systemd-run --unit="$unit" -p Type=oneshot -p User=5001 -p Group=100 -p SmackProcessLabel=System /bin/bash -c 'exec > /run/tizenguard/background-deactivate.log 2>&1; set -e; for a in com.samsung.tizen.smartthings-client com.samsung.tizen.smartthings-thing com.samsung.tv.mde-framework com.samsung.tv.device-assistant-service com.samsung.tv.device-assistant-viewer-app NRi6kdBYJ0.AirPlayWebApp com.samsung.tv.airplay-app com.samsung.tv.airplay-service com.samsung.tv.tvplus com.samsung.tv.tvPlusDeeplinker com.samsung.tv.slive-daemon org.tizen.bms-service org.tizen.primevideo org.tizen.primevideo-dummy org.tizen.primevideo_companionapp 30IKH0OX8U.TestBGService 30IKH0OX8U.cwservice 30IKH0OX8U.tilesservice org.tizen.tts-engine-vd-ATSC org.tizen.tts-engine-vd-ATSC-sr org.tizen.tts-engine-vd-ATSC-noti org.tizen.tts-engine-vd-ATSC-interrupt org.tizen.register-device-ux org.tizen.easysetup-daemon; do /usr/bin/pkgcmd -D -t app -n "$a" --global --uid 5001 || true; done; for e in com.samsung.tv.aria-video com.samsung.tv.aria-dummy com.samsung.tv.gamebar com.samsung.tv.store org.volt.apps com.samsung.tv.coba.apps org.tizen.content-tiles-provider ContentServiceManager com.samsung.tv.waapp-contents-provider com.samsung.tv.sboard-app; do /usr/bin/pkgcmd -A -t app -n "$e" --global --uid 5001 || true; done; echo NATIVE_DISABLE_DONE'
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if grep -qx NATIVE_DISABLE_DONE "$log"; then break; fi
  sleep 1
done
cat "$log"
sqlite3 -bail -cmd '.timeout 15000' /opt/dbspace/.pkgmgr_parser.db "BEGIN IMMEDIATE; UPDATE package_info SET package_disable='true',package_nodisplay='true' WHERE package IN (SELECT package FROM package_app_info WHERE app_id IN ($bg_sql)); UPDATE package_app_info SET app_disable='true',app_onboot='false',app_autorestart='false',app_preload='false',app_nodisplay='true' WHERE app_id IN ($bg_sql); INSERT OR REPLACE INTO package_app_info_for_uid (app_id,uid,is_disabled,is_splash_screen_enabled) SELECT app_id,5001,'true','true' FROM package_app_info WHERE app_id IN ($bg_sql); DELETE FROM package_app_info_for_uid WHERE app_id IN ('TizenTubeS.TizenTube','TizenTubeS.StandaloneService','org.tizen.netflix-app','com.samsung.tv.aria-video','com.samsung.tv.aria-dummy','com.samsung.tv.aria-engine','com.samsung.tv.gamebar','org.tizen.menu','org.tizen.tv-viewer','org.tizen.ambientapp','com.samsung.tv.store','org.volt.apps','com.samsung.tv.coba.apps','org.tizen.content-tiles-provider','ContentServiceManager','com.samsung.tv.waapp-contents-provider','com.samsung.tv.cis','com.samsung.tv.cis-api-service-app','WykOS4t4F0.cmsWebApp','ZODRT12q2l.WebAccountExtension','com.samsung.tv.sboard-app','com.samsung.hitcomp','com.samsung.tv.coba.privacychoice'); COMMIT;"
grep -qx NATIVE_DISABLE_DONE "$log"
echo BACKGROUND_NATIVE_DEACTIVATION_VERIFIED

# 4. Disable prelaunch.support in web app config.xml files (preserving backups in $BASE/backup/).
for p in 9Ur5IzDKqV 30IKH0OX8U aQjWjLsPaO ZODRT12q2l; do
  f="/opt/usr/apps/$p/res/config.xml"
  if test -f "$f" && grep -Fq 'key="http://samsung.com/tv/metadata/prelaunch.support" value="true"' "$f"; then
    test -f "$BASE/backup/$p-config.xml.bak" || cp -a "$f" "$BASE/backup/$p-config.xml.bak"
    rm -f "$f.tizenguard-tmp"
    cp -a "$f" "$f.tizenguard-tmp"
    sed 's@key="http://samsung.com/tv/metadata/prelaunch.support" value="true"@key="http://samsung.com/tv/metadata/prelaunch.support" value="false"@' "$f" > "$f.tizenguard-tmp"
    grep -Fq 'prelaunch.support" value="false"' "$f.tizenguard-tmp"
    mv "$f.tizenguard-tmp" "$f"
  fi
done

# 5. Enforce comprehensive SQLite package/app disablement, metadata cleanup, and TV Plus triggers.
sqlite3 -bail /opt/dbspace/.pkgmgr_parser.db <<'SQL'
.timeout 15000
BEGIN IMMEDIATE;
CREATE TEMP TABLE guard(ok INTEGER CHECK(ok=1));
INSERT INTO guard SELECT count(*)=7 FROM package_app_info WHERE app_id IN ('TizenTubeS.TizenTube','TizenTubeS.StandaloneService','org.tizen.netflix-app','com.samsung.tv.aria-video','org.tizen.menu','org.tizen.tv-viewer','com.samsung.tv.gamebar') AND app_disable='false';

CREATE TEMP TABLE disable_targets(app_id TEXT PRIMARY KEY);
INSERT OR IGNORE INTO disable_targets VALUES
('3KA0pm7a7V.TubiTV'),('3KA0pm7a7V.preview'),
('9TYrsHWbaB.ContinueWatchingService'),('9TYrsHWbaB.klyq'),
('GHI3a0zMSx.Service'),('GHI3a0zMSx.XboxGamePass'),
('HupEmjIB4I.Glance'),('LBUAQX1exg.Hulu'),
('MCmYXNxgcu.DisneyPlus'),('MCmYXNxgcu.DisneyPlusService'),
('NRi6kdBYJ0.AirPlayWebApp'),
('ZmmGjO6VKO.slingtv'),('ZmmGjO6VKO.slingtvBgservice'),
('aQjWjLsPaO.MultiScreenWebLauncher'),
('adplatform.ADPlayer'),
('com.samsung.tizen.samsung-analytics'),
('com.samsung.tizen.smartthings-client'),('com.samsung.tizen.smartthings-thing'),
('com.samsung.tv.acr'),
('com.samsung.tv.action-planner-service'),
('com.samsung.tv.ad-web-framework'),
('com.samsung.tv.adagent-service'),('com.samsung.tv.pisa-service'),('org.tizen.pisa-control-service'),
('com.samsung.tv.adplayer'),
('com.samsung.tv.airplay-app'),('com.samsung.tv.airplay-service'),
('com.samsung.tv.alexa-client'),('com.samsung.tv.alexa-fullscreen-app'),
('com.samsung.tv.bixby-context-client'),('com.samsung.tv.bixby-prov'),('com.samsung.tv.bixbycapsuleviewer'),
('com.samsung.tv.canalysis-service'),
('com.samsung.tv.cnvoice'),('com.samsung.tv.cnvoice-assistant'),
('com.samsung.tv.coba.ambient'),('com.samsung.tv.coba.ambientcontentabout'),('com.samsung.tv.coba.ambientcontentapp'),('com.samsung.tv.coba.ambientcontentart'),('com.samsung.tv.coba.ambientcontentroutine'),('com.samsung.tv.coba.ambientsetting'),('com.samsung.tv.coba.ambienttv'),
('com.samsung.tv.coba.healthview'),('com.samsung.tv.coba.multiscreen'),('com.samsung.tv.coba.smartthings'),
('com.samsung.tv.cobalt-app-test'),('com.samsung.tv.cobalt-gpm'),('com.samsung.tv.cobalt-stadia'),('com.samsung.tv.cobalt-ytkids'),('com.samsung.tv.cobalt-yttv'),
('com.samsung.tv.contents-recognition-dbmgr'),('com.samsung.tv.nvision-analysis-dbmgr'),('com.samsung.tv.vision-data-recognition-service'),('content-grab-service'),
('com.samsung.tv.context-aware-agent'),('com.samsung.tv.context-aware-agent-toast-view'),('com.samsung.tv.context-aware-grab-control'),('com.samsung.tv.context-aware-server-requester'),('com.samsung.tv.context-aware-service'),
('com.samsung.tv.device-assistant-service'),('com.samsung.tv.device-assistant-viewer-app'),
('com.samsung.tv.digitalbutler-app'),('com.samsung.tv.digitalbutler-daemon'),
('com.samsung.tv.easysetup-mediator'),('org.tizen.easysetup-UI'),('org.tizen.easysetup-daemon'),
('com.samsung.tv.farfieldvoice'),
('com.samsung.tv.fuzzy-search-engine'),
('com.samsung.tv.gallery'),
('com.samsung.tv.google-assistant'),('com.samsung.tv.google-fullscreen-app'),
('com.samsung.tv.iot-service-home-cctv_FLUX'),('com.samsung.tv.iot-service-notification'),
('com.samsung.tv.lightweight-node-service'),
('com.samsung.tv.mde-framework'),
('com.samsung.tv.multiscreen'),
('com.samsung.tv.mybixby'),
('com.samsung.tv.nfc-daemon'),('com.samsung.tv.nfc-monitor'),
('com.samsung.tv.ondevice-voice'),
('com.samsung.tv.preview-downloader'),('com.samsung.tv.preview-updater'),
('com.samsung.tv.samsung-health'),('samsunghealth-service-tv'),
('com.samsung.tv.slive-daemon'),('org.tizen.bms-service'),
('com.samsung.tv.targeted-ad-service'),
('com.samsung.tv.tvPlusDeeplinker'),('com.samsung.tv.tvplus'),
('com.samsung.tv.utterance-recommender-app'),('com.samsung.tv.utterance-recommender-core'),
('com.samsung.tv.vif'),
('com.samsung.tv.voiceassistant-music'),
('com.samsung.tv.wakeup-engine-alexa'),('com.samsung.tv.wakeup-engine-bixby'),
('com.samsung.tv.wifi-motion-service-app'),
('com.samsung.tv.simpletext-tpl'),('com.samsung.tv.lightgrid-tpl'),('com.samsung.tv.bouroullecwidget-tpl'),('com.samsung.tv.vibe-tpl'),('com.samsung.tv.vibeglwidget-tpl'),('com.samsung.tv.mountainview-tpl'),('com.samsung.tv.cinemagraph-relaxation'),('com.samsung.tv.DynamicFilter'),('com.samsung.tv.tranquilnature-tpl'),
('gzcc4LRFBF.ContinueWatchingService'),('gzcc4LRFBF.Peacock'),('gzcc4LRFBF.service'),
('jAfAs7yVDX.TheSix'),('jAfAs7yVDX.rpservice'),
('oKZtnuTBW8.emanual'),
('XPkceUl3N4.UsbCamApp'),
('tv6pbVMQFF.PrivacyChoices'),
('30IKH0OX8U.TestBGService'),('30IKH0OX8U.cwservice'),('30IKH0OX8U.tilesservice'),
('9Ur5IzDKqV.TizenYouTube'),
('org.tizen.browser'),
('org.tizen.primevideo'),('org.tizen.primevideo-dummy'),('org.tizen.primevideo_companionapp'),
('org.tizen.ScreenMirroring-app-tv'),
('org.tizen.hbbtv'),('org.tizen.hbbtv-service'),
('org.tizen.multi-assistant-service'),
('org.tizen.register-device-ux'),
('org.tizen.remotepc'),
('org.tizen.tts-engine-vd-ATSC'),('org.tizen.tts-engine-vd-ATSC-interrupt'),('org.tizen.tts-engine-vd-ATSC-noti'),('org.tizen.tts-engine-vd-ATSC-sr'),
('org.tizen.voice-app'),('org.tizen.voice-app-service'),('org.tizen.voice-client'),('org.tizen.voice-onboarding'),
('org.tizen.welcome-mode'),
('yL49PNFmjW.PromotionApp'),('yL49PNFmjW.service'),
('zigzSWa1hy.InstagramAirwave');

UPDATE package_info SET package_disable='true',package_nodisplay='true'
 WHERE package IN (SELECT package FROM package_app_info WHERE app_id IN (SELECT app_id FROM disable_targets))
   AND package NOT IN ('com.samsung.tv.cobalt','TizenTubeS','org.tizen.netflix-app','com.samsung.tv.aria-video','com.samsung.tv.aria-engine','lib-ariafw-tv','com.samsung.tv.gamebar','org.tizen.menu','org.tizen.tv-viewer','org.tizen.ambientapp','TizenGuard','com.samsung.tv.store','com.samsung.tv.coba.apps','org.tizen.content-tiles-provider','ContentServiceManager','com.samsung.tv.waapp-contents-provider','com.samsung.tv.cis-service-app','com.samsung.tv.cis-api-service-app','WykOS4t4F0','ZODRT12q2l','com.samsung.tv.sboard-app','com.samsung.hitcomp','com.samsung.tv.coba.privacy_app');

UPDATE package_app_info SET app_disable='true',app_nodisplay='true',app_preload='false',app_onboot='false',app_autorestart='false'
 WHERE app_id IN (SELECT app_id FROM disable_targets);

INSERT OR REPLACE INTO package_app_info_for_uid (app_id, uid, is_disabled, is_splash_screen_enabled)
 SELECT app_id, 5001, 'true', 'true' FROM package_app_info WHERE app_disable='true';

UPDATE package_app_info SET app_preload='false',app_onboot='false',app_autorestart='false'
 WHERE app_id IN ('com.samsung.tv.gamebar','com.samsung.tv.aria-video','com.samsung.tv.aria-dummy');

UPDATE package_app_app_metadata SET md_value='false'
 WHERE md_key='http://samsung.com/tv/metadata/prelaunch.support'
   AND app_id NOT IN ('org.tizen.netflix-app','com.samsung.tv.aria-video','TizenTubeS.TizenTube');

UPDATE package_app_app_metadata SET md_value='none'
 WHERE md_key='http://samsung.com/tv/metadata/background-update';

UPDATE package_info SET package_disable='false' WHERE package='org.tizen.ambientapp';
UPDATE package_app_info SET app_disable='false' WHERE app_id='org.tizen.ambientapp';
DELETE FROM package_app_info_for_uid WHERE uid=5001 AND app_id='org.tizen.ambientapp';

CREATE TRIGGER tizenguard_tvplus_app_disabled AFTER UPDATE OF app_disable,app_preload,app_onboot,app_autorestart ON package_app_info
WHEN NEW.app_id IN ('com.samsung.tv.tvplus','com.samsung.tv.tvPlusDeeplinker','com.samsung.tv.slive-daemon','org.tizen.bms-service')
 AND (NEW.app_disable!='true' OR NEW.app_preload!='false' OR NEW.app_onboot!='false' OR NEW.app_autorestart!='false')
BEGIN
 UPDATE package_app_info SET app_disable='true',app_preload='false',app_onboot='false',app_autorestart='false',app_nodisplay='true' WHERE app_id=NEW.app_id;
END;

CREATE TRIGGER tizenguard_tvplus_package_disabled AFTER UPDATE OF package_disable,package_nodisplay ON package_info
WHEN NEW.package IN ('com.samsung.tv.tvplus','com.samsung.tv.tvPlusDeeplinker','com.samsung.tv.slive-daemon')
 AND (NEW.package_disable!='true' OR NEW.package_nodisplay!='true')
BEGIN
 UPDATE package_info SET package_disable='true',package_nodisplay='true' WHERE package=NEW.package;
END;

DROP TABLE disable_targets;
DROP TABLE guard;
COMMIT;
SQL

sqlite3 -bail /opt/dbspace/.webappservice.db <<'SQL'
.timeout 15000
BEGIN IMMEDIATE;
UPDATE widgetinfo SET is_hidden=0,is_display=1,is_app_available=1,install_state=3
 WHERE id IN ('TizenTubeS.TizenTube','3201907018807','3201807016597');
UPDATE widgetinfo SET is_hidden=1,is_display=0,is_app_available=0
 WHERE (pkgname IN ('3KA0pm7a7V','9TYrsHWbaB','GHI3a0zMSx','HupEmjIB4I','LBUAQX1exg','MCmYXNxgcu','NRi6kdBYJ0','ZmmGjO6VKO','aQjWjLsPaO','com.samsung.tizen.smartthings-client','com.samsung.tizen.smartthings-thing','com.samsung.tv.airplay-app','com.samsung.tv.bixby-context-client','com.samsung.tv.bixby-prov','com.samsung.tv.bixbycapsuleviewer','com.samsung.tv.cnvoice','com.samsung.tv.cnvoice-assistant','com.samsung.tv.coba.healthview','com.samsung.tv.coba.multiscreen','com.samsung.tv.coba.smartthings','com.samsung.tv.farfieldvoice','com.samsung.tv.gallery','com.samsung.tv.gamebar','com.samsung.tv.iot-service-home-cctv_FLUX','com.samsung.tv.iot-service-notification','com.samsung.tv.multiscreen','com.samsung.tv.mybixby','com.samsung.tv.nfc-daemon','com.samsung.tv.nfc-monitor','com.samsung.tv.ondevice-voice','com.samsung.tv.preview-downloader','com.samsung.tv.preview-updater','com.samsung.tv.samsung-health','com.samsung.tv.targeted-ad-service','com.samsung.tv.tvPlusDeeplinker','com.samsung.tv.tvplus','com.samsung.tv.voiceassistant-music','com.samsung.tv.wakeup-engine-bixby','com.samsung.tv.wifi-motion-service-app','gzcc4LRFBF','jAfAs7yVDX','oKZtnuTBW8','org.tizen.primevideo','org.tizen.ScreenMirroring-app-tv','org.tizen.remotepc','org.tizen.voice-app','org.tizen.voice-client','org.tizen.voice-onboarding','ug-hbbtv-efl','yL49PNFmjW','zigzSWa1hy')
    OR tizen_id IN ('org.tizen.browser','9Ur5IzDKqV.TizenYouTube','oKZtnuTBW8.emanual','org.tizen.primevideo'))
   AND id NOT IN ('TizenTubeS.TizenTube','3201907018807','3201807016597','3201901017624','3201911019599','3202101022708','TizenGuard.App')
   AND pkgname NOT IN ('com.hbo.hbomax','com.wbd.stream','org.tizen.hbomax')
   AND (title IS NULL OR (title NOT LIKE '%HBO%' AND title NOT LIKE '%Max%'));
UPDATE widgetinfo SET is_hidden=1,is_display=1,is_app_available=1
 WHERE id IN ('3201901017624','3201911019599','3202101022708');
UPDATE widgetinfo SET is_hidden=1,is_display=0,is_app_available=1
 WHERE id='TizenGuard.App';
COMMIT;
SQL

# 6. Mask and stop all non-essential telemetry, ad, ACR, voice, cloud, discovery, and background-update systemd units.
units="reclaimd.service com.samsung.tv.context-aware-agent.path com.samsung.tv.context-aware-agent.service com.samsung.tv.context-aware-service.path com.samsung.tv.context-aware-service.service abnormal_user_behavior.service emergency-log-transmitter.service issue_report_agent.service wifi-presence.service mde-framework.service com.samsung.tv.device-assistant-service.service adagent-service.service allshare-svc.service ambient-ua-agent.service bms.path bms.service canalysis-service.service com.samsung.tv.airplay-service.path com.samsung.tv.airplay-service.service com.samsung.tv.airplay-service-2.path com.samsung.tv.airplay-service-2.service com.samsung.tv.farfieldvoice.path com.samsung.tv.farfieldvoice.service com.samsung.tv.multiscreen.service com.samsung.tv.nfc-daemon.service com.samsung.tv.ondevice-voice.path com.samsung.tv.ondevice-voice.service com.samsung.tv.preview-updater.service com.samsung.tv.voiceassistant-music.service com.samsung.tv.wifi-motion-mgr.service content-grab-service.path content-grab-service.service contents-recognition-service.service contents-ui-detector-service.service vision-data-recognition-service.path vision-data-recognition-service.service data-service.service kpi-logging.service media-analytics-service.service mirroring-recognition-manager.service org.tizen.remotepc.service org.tizen.tv.sp-kpi.service org.tizen.voice-app.path org.tizen.voice-app.service org.tizen.multi-assistant-service.path org.tizen.multi-assistant-service.service pisa-service.path pisa-service.service pisa-service.socket samsunghealth-service-tv-dbus-activation.service samsunghealth-service-tv-path-activation.path samsunghealth-service-tv-path-activation.service samsunghealth-service-tv.path samsunghealth-service-tv.service slive-provider-daemon.path slive-provider-daemon.service hbbtv-service.path hbbtv-service.service org.tizen.art-app.path org.tizen.art-app.service devicetracker.service org.tizen.tv.tagpro-service-tv.service register-device.service org.tizen.easysetup-daemon.service swu-auto-upgrade.service swu-auto-upgrade.timer was-background-update.service vdsystem-update-manager.timer vdsystem-update-manager.service ai-abr-download-manager.timer ai-abr-download-manager.service camera-conf-mgr-abm-tv.timer camera-conf-mgr-abm-tv.service dlogutil.timer dlog_logger.service stability-monitor.service boot-perfmon-tv.service socite-remote.service scs-agent.service pushd.service csf-content-engine.service color-pick.service mvpd-service.service vd_dmr.service screen_sharing.service wfd-manager.service audio-share.service sddp.service org.tizen.NPUManager.service org.tizen.UsbSyncDisplay.service connman-logger.service smack-logger.service vddebugmenu.service"
for u in $units; do
  if test ! -e /run/systemd/system/"$u" && test ! -L /run/systemd/system/"$u"; then
    ln -s /dev/null /run/systemd/system/"$u"
  fi
done
systemctl daemon-reload
systemctl --no-block stop $units || true
sleep 4
for u in $units; do
  case "$(systemctl is-active "$u" || true)" in
    deactivating) systemctl kill --kill-who=all --signal=SIGKILL "$u" || true ;;
  esac
done

for a in com.samsung.tv.multiscreen com.samsung.tv.airplay-app com.samsung.tv.airplay-service NRi6kdBYJ0.AirPlayWebApp 30IKH0OX8U.TestBGService 30IKH0OX8U.cwservice 30IKH0OX8U.tilesservice com.samsung.tv.preview-updater org.tizen.hbbtv org.tizen.hbbtv-service org.tizen.primevideo org.tizen.primevideo-dummy org.tizen.primevideo_companionapp org.tizen.welcome-mode org.tizen.register-device-ux org.tizen.easysetup-daemon org.tizen.tts-engine-vd-ATSC-sr org.tizen.tts-engine-vd-ATSC org.tizen.tts-engine-vd-ATSC-noti org.tizen.tts-engine-vd-ATSC-interrupt com.samsung.tv.tvplus com.samsung.tv.tvPlusDeeplinker com.samsung.tv.slive-daemon org.tizen.bms-service; do
  app_launcher -u 5001 -t "$a" >/dev/null 2>&1 || true
done

killall -9 reclaimd dotnet-memory-reclaimer utterance-recommender-core utterance-recom org.tizen.multi org.tizen.multi-assistant-service fuzzy-search-en fuzzy-search-engine context-aware-a context-aware-agent digitalbutler-d digitalbutler-daemon action-planner- action-planner-service ffv-service tts-engine-vd-s tts-engine-vd-sr tts-engine-vd register-device register-device-ux tztv-tagpro-dae tztv-tagpro-daemon org.tizen.easys org.tizen.easysetup-daemon SWUAutoUpgrade was_background_ was_background_update CheckProgramCha dmr pushd stability-monit stability-monitor screen_sharing wfd-manager p2p-asm color-pick mvpd_native audio-share welcome-mode csf-content-eng csf-content-engine connman-logger boot-perfmon-tv socite_service SCSAgent SDDP npumgr_server usdmanagerlaunc usdmanagerlauncher smack-logger tvplus slive-provider- slive-provider-daemon bms-service spotifyd primevideo pvcompanionapp 30IKH0OX8U.cwse 30IKH0OX8U.tile 30IKH0OX8U.Test 2>/dev/null || true

# 7. Fluency profile: native CSFS NUI/Flux animation switch, CPU governor, eMMC queue, VM/reclaimd/resourced/dyboost, and UI/Media/HDMI cgroup/nice guardian.
printf 'off' > /opt/usr/home/owner/share/animation
chown 5001:5001 /opt/usr/home/owner/share/animation
chmod 644 /opt/usr/home/owner/share/animation
chsmack -a '*' /opt/usr/home/owner/share/animation

for c in /sys/devices/system/cpu/cpu[0-3]/cpufreq; do
  echo 1700000 > "$c/scaling_max_freq" 2>/dev/null || true
  echo 1700000 > "$c/scaling_min_freq" 2>/dev/null || true
done
if test -d /sys/devices/system/cpu/cpufreq/interactive; then
  echo 60 > /sys/devices/system/cpu/cpufreq/interactive/go_hispeed_load 2>/dev/null || true
  echo 70 > /sys/devices/system/cpu/cpufreq/interactive/target_loads 2>/dev/null || true
  echo 20000 > /sys/devices/system/cpu/cpufreq/interactive/timer_rate 2>/dev/null || true
  echo 60000 > /sys/devices/system/cpu/cpufreq/interactive/min_sample_time 2>/dev/null || true
  echo 10000 > /sys/devices/system/cpu/cpufreq/interactive/above_hispeed_delay 2>/dev/null || true
  echo 1 > /sys/devices/system/cpu/cpufreq/interactive/io_is_busy 2>/dev/null || true
fi
echo noop > /sys/block/mmcblk0/queue/scheduler 2>/dev/null || true
echo 256 > /sys/block/mmcblk0/queue/read_ahead_kb 2>/dev/null || true
echo 2 > /sys/block/mmcblk0/queue/rq_affinity 2>/dev/null || true
echo 256 > /sys/block/mmcblk0/queue/nr_requests 2>/dev/null || true

umount /etc/reclaimd/black_list 2>/dev/null || true
cat /etc/reclaimd/black_list > "$RUN/reclaimd_black_list"
cat >> "$RUN/reclaimd_black_list" <<'EOF'
DN_sung.tv.csfs 0
csfs 0
enlightenment 0
menu 0
org.tizen.menu 0
tv-viewer 0
org.tizen.tv-viewer 0
WLaunch 0
cobalt_launcher 0
GIBBON_MAIN 0
aria-engine 0
tvs-daemon 0
tvs-lite 0
hdmicec-service 0
source-service 0
EOF
chsmack -a '_' "$RUN/reclaimd_black_list"
mount --bind "$RUN/reclaimd_black_list" /etc/reclaimd/black_list

umount /etc/resourced/memory.conf 2>/dev/null || true
sed -e 's/^AfterScreenDim=yes/AfterScreenDim=no/' /etc/resourced/memory.conf > "$RUN/resourced_memory.conf"
chsmack -a '_' "$RUN/resourced_memory.conf"
mount --bind "$RUN/resourced_memory.conf" /etc/resourced/memory.conf

umount /etc/resourced/cpu.conf 2>/dev/null || true
sed -e 's/^BACKGROUND_CPU_SHARE=50/BACKGROUND_CPU_SHARE=512/' /etc/resourced/cpu.conf > "$RUN/resourced_cpu.conf"
chsmack -a '_' "$RUN/resourced_cpu.conf"
mount --bind "$RUN/resourced_cpu.conf" /etc/resourced/cpu.conf

if test -f /usr/apps/boot-helper-dyboost-tv/res/dybrules.conf; then
  umount /usr/apps/boot-helper-dyboost-tv/res/dybrules.conf 2>/dev/null || true
  sed 's/^CSFS csfs 5csfs:/CSFS DN_sung.tv.csfs 5DN_sung.tv.csfs:/' /usr/apps/boot-helper-dyboost-tv/res/dybrules.conf > "$RUN/dybrules.conf"
  chsmack -a '_' "$RUN/dybrules.conf"
  mount --bind "$RUN/dybrules.conf" /usr/apps/boot-helper-dyboost-tv/res/dybrules.conf
fi

sysctl -w vm.swappiness=5 vm.vfs_cache_pressure=120 vm.dirty_background_ratio=5 vm.dirty_ratio=15 >/dev/null

swap_used=$(awk '/\/dev\/zram0/ {print $4}' /proc/swaps 2>/dev/null || echo 0)
if test "${swap_used:-0}" -gt 1024; then
  systemd-run --no-block --unit="tizenguard-zram-drain-$(date +%s)" -p Type=oneshot -p User=0 -p Group=0 -p SmackProcessLabel=System /bin/bash -c 'swapoff /dev/zram0 && swapon -p 100 /dev/zram0' >/dev/null 2>&1 || true
fi

cat > "$RUN/ui-guardian.sh" <<'GUARDIAN_EOF'
#!/bin/sh
printf System > /proc/self/attr/current 2>/dev/null || true
if [ -f /sys/fs/cgroup/cpu/Booster/cpu.shares ]; then
  echo 1024 > /sys/fs/cgroup/cpu/Booster/cpu.shares 2>/dev/null || true
fi
if [ -f /sys/fs/cgroup/cpu/Background/cpu.shares ]; then
  echo 512 > /sys/fs/cgroup/cpu/Background/cpu.shares 2>/dev/null || true
fi
while true; do
  for cpufreq in /sys/devices/system/cpu/cpu[0-3]/cpufreq; do
    echo 1700000 > "$cpufreq/scaling_max_freq" 2>/dev/null || true
    echo 1700000 > "$cpufreq/scaling_min_freq" 2>/dev/null || true
  done
  for c in enlightenment DN_sung.tv.csfs; do
    for p in $(pgrep -x "$c" 2>/dev/null || true); do
      renice -n -10 -p "$p" >/dev/null 2>&1 || true
      echo -900 > "/proc/$p/oom_score_adj" 2>/dev/null || true
      for tid in /proc/"$p"/task/*; do
        t="${tid##*/}"
        echo "$t" > /sys/fs/cgroup/cpu/tasks 2>/dev/null || true
        renice -n -10 -p "$t" >/dev/null 2>&1 || true
      done
    done
  done
  for c in menu tv-viewer tvs-daemon tvs-lite hdmicec-service source-service gamepad-service bt-service deviced WLaunch cobalt_launcher GIBBON_MAIN aria-engine aria-video; do
    for p in $(pgrep -x "$c" 2>/dev/null || true); do
      renice -n -6 -p "$p" >/dev/null 2>&1 || true
      for tid in /proc/"$p"/task/*; do
        t="${tid##*/}"
        echo "$t" > /sys/fs/cgroup/cpu/tasks 2>/dev/null || true
        renice -n -6 -p "$t" >/dev/null 2>&1 || true
      done
    done
  done
  sleep 15
done
GUARDIAN_EOF
chmod 644 "$RUN/ui-guardian.sh"
chsmack -a System "$RUN/ui-guardian.sh"

cat > "$RUN/tizenguard-ui-guardian.service.new" <<'EOF'
[Unit]
Description=TizenGuard UI Priority and Cgroup Guardian
After=multi-user.target

[Service]
Type=simple
User=0
Group=0
SmackProcessLabel=System
ExecStart=/bin/sh /run/tizenguard/ui-guardian.sh
Restart=always
RestartSec=5
EOF
if ! cmp -s "$RUN/tizenguard-ui-guardian.service.new" /run/systemd/system/tizenguard-ui-guardian.service 2>/dev/null; then
  mv -f "$RUN/tizenguard-ui-guardian.service.new" /run/systemd/system/tizenguard-ui-guardian.service
  chsmack -a System /run/systemd/system/tizenguard-ui-guardian.service
  systemctl daemon-reload
  systemctl restart tizenguard-ui-guardian.service 2>/dev/null || true
else
  rm -f "$RUN/tizenguard-ui-guardian.service.new"
  if test "$(systemctl is-active tizenguard-ui-guardian.service 2>/dev/null || true)" != active; then
    systemctl restart tizenguard-ui-guardian.service 2>/dev/null || true
  fi
fi

for pid in $(pgrep -f '^/bin/sh /usr/bin/ambient_start.sh$' || true); do kill -CONT "$pid" || true; done

# Preserve SmartThings global package_disable/app_disable='false' while keeping uid=5001 is_disabled='true' so boot preload repair does not reinstall and wipe uid=5001 rows.
sqlite3 -bail -cmd '.timeout 15000' /opt/dbspace/.pkgmgr_parser.db "BEGIN IMMEDIATE; UPDATE package_info SET package_disable='false' WHERE package IN ('com.samsung.tizen.smartthings-client','com.samsung.tizen.smartthings-thing'); UPDATE package_app_info SET app_disable='false',app_onboot='false',app_autorestart='false',app_preload='false' WHERE app_id IN ('com.samsung.tizen.smartthings-client','com.samsung.tizen.smartthings-thing'); INSERT OR REPLACE INTO package_app_info_for_uid (app_id,uid,is_disabled,is_splash_screen_enabled) VALUES ('com.samsung.tizen.smartthings-client',5001,'true','true'),('com.samsung.tizen.smartthings-thing',5001,'true','true'); COMMIT;"

sqlite3 -readonly -cmd '.timeout 15000' /opt/dbspace/.pkgmgr_parser.db 'pragma quick_check;'
sqlite3 -readonly -cmd '.timeout 15000' /opt/dbspace/.webappservice.db 'pragma quick_check;'
echo TIZENGUARD_PROFILE_APPLIED
