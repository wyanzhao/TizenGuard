'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

test('SQLite TV Plus triggers block re-enablement and check-policy SQL guards validate core & owner rows', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tizenguard-sql-'));
  const dbPath = path.join(dir, 'pkgmgr.db');

  try {
    const setupSql = `
CREATE TABLE package_info (
  package TEXT PRIMARY KEY,
  package_disable TEXT,
  package_nodisplay TEXT
);
CREATE TABLE package_app_info (
  app_id TEXT PRIMARY KEY,
  package TEXT,
  app_disable TEXT,
  app_nodisplay TEXT,
  app_preload TEXT,
  app_onboot TEXT,
  app_autorestart TEXT
);
CREATE TABLE package_app_info_for_uid (
  app_id TEXT,
  uid INTEGER,
  is_disabled TEXT,
  is_splash_screen_enabled TEXT,
  PRIMARY KEY (app_id, uid)
);

INSERT INTO package_info VALUES
  ('TizenGuard', 'false', 'false'),
  ('TizenTubeS', 'false', 'false'),
  ('org.tizen.netflix-app', 'false', 'false'),
  ('com.samsung.tv.cobalt-launcher', 'false', 'false'),
  ('org.tizen.synapse-voice', 'false', 'false'),
  ('com.samsung.tv.tvplus', 'true', 'true'),
  ('com.samsung.tv.tvPlusDeeplinker', 'true', 'true');

INSERT INTO package_app_info VALUES
  ('TizenGuard.App', 'TizenGuard', 'false', 'false', 'false', 'false', 'false'),
  ('TizenGuard.Service', 'TizenGuard', 'false', 'true', 'false', 'true', 'true'),
  ('TizenTubeS.TizenTube', 'TizenTubeS', 'false', 'false', 'false', 'false', 'false'),
  ('TizenTubeS.StandaloneService', 'TizenTubeS', 'false', 'true', 'false', 'false', 'true'),
  ('org.tizen.netflix-app', 'org.tizen.netflix-app', 'false', 'false', 'false', 'false', 'false'),
  ('com.samsung.tv.cobalt-launcher', 'com.samsung.tv.cobalt-launcher', 'false', 'false', 'false', 'false', 'false'),
  ('org.tizen.synapse-voice', 'org.tizen.synapse-voice', 'false', 'true', 'false', 'false', 'false'),
  ('com.samsung.tv.tvplus', 'com.samsung.tv.tvplus', 'true', 'true', 'false', 'false', 'false'),
  ('com.samsung.tv.tvPlusDeeplinker', 'com.samsung.tv.tvPlusDeeplinker', 'true', 'true', 'false', 'false', 'false');

CREATE TRIGGER tizenguard_tvplus_app_disabled
AFTER UPDATE OF app_disable, app_preload, app_onboot, app_autorestart ON package_app_info
WHEN NEW.app_id IN ('com.samsung.tv.tvplus', 'com.samsung.tv.tvPlusDeeplinker')
 AND (NEW.app_disable != 'true' OR NEW.app_preload != 'false' OR NEW.app_onboot != 'false' OR NEW.app_autorestart != 'false')
BEGIN
  UPDATE package_app_info
     SET app_disable='true', app_preload='false', app_onboot='false', app_autorestart='false', app_nodisplay='true'
   WHERE app_id=NEW.app_id;
END;

CREATE TRIGGER tizenguard_tvplus_package_disabled
AFTER UPDATE OF package_disable, package_nodisplay ON package_info
WHEN NEW.package IN ('com.samsung.tv.tvplus', 'com.samsung.tv.tvPlusDeeplinker')
 AND (NEW.package_disable != 'true' OR NEW.package_nodisplay != 'true')
BEGIN
  UPDATE package_info
     SET package_disable='true', package_nodisplay='true'
   WHERE package=NEW.package;
END;
`;
    execFileSync('sqlite3', [dbPath, setupSql]);

    // Simulate Samsung Cloud / Smart Hub syncing TV Plus back to enabled
    execFileSync('sqlite3', [
      dbPath,
      `UPDATE package_info SET package_disable='false', package_nodisplay='false' WHERE package='com.samsung.tv.tvplus';
       UPDATE package_app_info SET app_disable='false', app_preload='true', app_onboot='true', app_autorestart='true' WHERE app_id='com.samsung.tv.tvplus';`,
    ]);

    const tvPlusState = execFileSync(
      'sqlite3',
      [
        dbPath,
        `SELECT p.package_disable, p.package_nodisplay, a.app_disable, a.app_preload, a.app_onboot, a.app_autorestart
           FROM package_info p JOIN package_app_info a ON p.package=a.package
          WHERE p.package='com.samsung.tv.tvplus';`,
      ],
      { encoding: 'utf8' }
    ).trim();
    assert.equal(tvPlusState, 'true|true|true|false|false|false');

    // Verify own_guard and core_guard queries from check-policy.sh return 0 violations
    const ownGuard = execFileSync(
      'sqlite3',
      [
        dbPath,
        `SELECT count(*) FROM package_info WHERE package='TizenGuard' AND package_disable!='false';
         SELECT count(*) FROM package_app_info WHERE app_id IN ('TizenGuard.App','TizenGuard.Service') AND app_disable!='false';
         SELECT count(*) FROM package_app_info WHERE app_id='TizenGuard.Service' AND (app_onboot!='true' OR app_autorestart!='true');
         SELECT count(*) FROM package_app_info_for_uid WHERE uid=5001 AND app_id IN ('TizenGuard.App','TizenGuard.Service') AND is_disabled!='false';`,
      ],
      { encoding: 'utf8' }
    ).trim();
    assert.equal(ownGuard, '0\n0\n0\n0');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
