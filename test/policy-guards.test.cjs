'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const policy = require('../widget/service/policy');

function makeValidConfig() {
  return {
    schema: 1,
    device: 'qn90a',
    enabled: true,
    apply_policy: true,
    port: 28443,
    firmware: 'T-NKM2AKUC-2310.0',
    sdk_host_ip: '198.51.100.25',
    client_sha256: 'a'.repeat(64),
    policy_sha256: 'b'.repeat(64),
    hashes: {
      '/usr/bin/dotnet': 'c'.repeat(64),
      '/usr/sbin/sdbd-tarlauncher': 'd'.repeat(64),
    },
    protected_hashes: {
      '/etc/passwd': 'e'.repeat(64),
      '/usr/share/sdbd/public.pem': 'f'.repeat(64),
    },
  };
}

test('config() validates all required fields including sdk_host_ip and SHA-256 pins', () => {
  const valid = makeValidConfig();
  assert.deepEqual(policy.config(valid), valid);

  assert.throws(
    () => policy.config({ ...valid, sdk_host_ip: '999.1.1.1' }),
    /Invalid sdk_host_ip/
  );
  assert.throws(
    () => policy.config({ ...valid, sdk_host_ip: '0.0.0.0' }),
    /Invalid sdk_host_ip/
  );
  assert.throws(
    () => policy.config({ ...valid, client_sha256: 'not-a-sha256' }),
    /Missing identity guards/
  );
  assert.throws(
    () => policy.config({ ...valid, hashes: { '/usr/bin/dotnet': 'c'.repeat(64) } }),
    /Missing launcher guards/
  );
});

test('sdkRuntimeGuard() builds deterministic SHA-256 preflight commands for launcher and protected files', () => {
  const cfg = makeValidConfig();
  const guardCmd = policy.sdkRuntimeGuard(cfg);
  assert.match(guardCmd, /sha256sum '\/usr\/bin\/dotnet'/);
  assert.match(guardCmd, /sha256sum '\/usr\/sbin\/sdbd-tarlauncher'/);
  assert.match(guardCmd, /sha256sum '\/etc\/passwd'/);
  assert.match(guardCmd, /sha256sum '\/usr\/share\/sdbd\/public\.pem'/);
});

test('Journal enforces replay protection and archives completed entries', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tizenguard-journal-'));
  const journalFile = path.join(dir, 'journal.json');
  try {
    const journal = new policy.Journal(journalFile);
    const req = {
      id: 'operation-00000001',
      command: 'echo test-1',
      timeout_ms: 5000,
    };
    journal.begin(req);
    assert.throws(
      () => journal.begin(req),
      /Request already submitted; inspect outcome, do not replay/
    );
    journal.finish(req.id, { exit_code: 0, timed_out: false });

    for (let i = 2; i <= 105; i++) {
      const id = `operation-${String(i).padStart(8, '0')}`;
      journal.begin({ id, command: `echo ${i}`, timeout_ms: 5000 });
      journal.finish(id, { exit_code: 0, timed_out: false });
    }
    const archived = journal.archive();
    assert.equal(archived.archived_entries, 5);
    assert.equal(archived.retained_entries, 100);
    assert.ok(fs.existsSync(journalFile + '.archives'));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
