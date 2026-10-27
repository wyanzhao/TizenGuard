'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const policy = require('../widget/service/policy');

function decodeWire(cmd) {
  const b64 = cmd.split(' ')[2];
  return Buffer.from(b64, 'base64').toString('utf8');
}

test('Boot window [180s..600s] applies once, checks drift, repairs exit 3, and releases root at >=600s', async () => {
  const dataPath = '/opt/usr/home/owner/apps_rw/TizenGuard/data';
  const cfg = {
    schema: 1,
    device: 'qn90a',
    enabled: true,
    apply_policy: true,
    port: 28443,
    firmware: 'T-NKM2AKUC-2310.0',
    sdk_host_ip: '198.51.100.10',
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

  let uptimeSeconds = 120;
  let fakeNow = 1000000;
  let connected = true;
  let stopCount = 0;
  let bootCallback = null;
  let checkExitCode = 0;
  const decodedScripts = [];

  const agent = {
    status: () => ({ connected }),
    start: () => {
      connected = true;
    },
    stop: () => {
      stopCount++;
      connected = false;
    },
    execute: async (cmd) => {
      const script = decodeWire(cmd);
      decodedScripts.push(script);
      if (script.includes('select count(*) from widgetinfo')) {
        return { exit_code: checkExitCode, timed_out: false, stdout: 'CHECK\n', stderr: '' };
      }
      return { exit_code: 0, timed_out: false, stdout: 'APPLIED\n', stderr: '' };
    },
  };

  const serviceDir = path.resolve(__dirname, '../widget/service');
  const mainSource = fs.readFileSync(path.join(serviceDir, 'main.js'), 'utf8');

  const fakeDate = Object.create(Date);
  fakeDate.now = () => fakeNow;

  vm.runInNewContext(mainSource, {
    __dirname: serviceDir,
    Buffer,
    Date: fakeDate,
    console,
    process: { on() {} },
    setInterval(fn) {
      bootCallback = fn;
      return 1;
    },
    clearInterval() {},
    setTimeout,
    require(name) {
      if (name === './agent') return { createAgent: () => agent };
      if (name === './policy') {
        return {
          ...policy,
          atomic() {},
          read(p) {
            if (p === dataPath + '/config.json') return Buffer.from(JSON.stringify(cfg));
            if (p.startsWith(dataPath + '/')) return Buffer.from('dummy-pem');
            if (p === '/proc/sys/kernel/random/boot_id') return Buffer.from('boot-abc');
            if (p === '/proc/uptime') return Buffer.from(`${uptimeSeconds} 0`);
            return fs.readFileSync(p);
          },
        };
      }
      if (name === 'https') {
        return {
          createServer() {
            return {
              on() {},
              listen(_p, _h, cb) {
                if (cb) cb();
              },
            };
          },
        };
      }
      return require(name);
    },
  });

  assert.equal(typeof bootCallback, 'function');

  // 1. Before 180s: no commands executed
  bootCallback();
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(decodedScripts.length, 0);

  // 2. At 200s: initial boot-policy apply runs
  uptimeSeconds = 200;
  bootCallback();
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(decodedScripts.length, 1);
  assert.match(decodedScripts[0], /\. \/opt\/usr\/share\/tizenguard\/boot-policy\.sh/);

  // 3. Advance clock by 125s at uptime 325s: first tick reconnects agent, second tick runs check-policy.sh (exit 0)
  uptimeSeconds = 325;
  fakeNow += 125000;
  checkExitCode = 0;
  bootCallback(); // starts agent
  bootCallback(); // runs check-policy.sh
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(decodedScripts.length, 2);
  assert.match(decodedScripts[1], /select count\(\*\) from widgetinfo/);

  // 4. Advance clock by 125s at uptime 450s: check-policy.sh returns exit 3 -> triggers automatic repair apply
  uptimeSeconds = 450;
  fakeNow += 125000;
  checkExitCode = 3;
  bootCallback(); // starts agent
  bootCallback(); // runs check-policy.sh -> exit 3 -> runs apply()
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(decodedScripts.length, 4);
  assert.match(decodedScripts[2], /select count\(\*\) from widgetinfo/);
  assert.match(decodedScripts[3], /\. \/opt\/usr\/share\/tizenguard\/boot-policy\.sh/);

  // 5. At 610s (>=600s): if agent is connected, tick stops root session
  uptimeSeconds = 610;
  connected = true;
  const stopsBefore = stopCount;
  bootCallback();
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(stopCount, stopsBefore + 1);
});
