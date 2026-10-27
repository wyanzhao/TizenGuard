'use strict';

const fs = require('fs');
const https = require('https');
const crypto = require('crypto');
const { read, atomic, hash, config } = require('./policy');
const { createAgent } = require('./agent');

const DATA = '/opt/usr/home/owner/apps_rw/TizenGuard/data';
const POLICY_SCRIPT = '/opt/usr/share/tizenguard/boot-policy.sh';
const RECOVERY_DLL = '/opt/usr/share/tizenguard/recovery/SdkHostRecovery.dll';
const APPLIED_MARKER = '/run/tizenguard/boot-policy-applied';

const C = config(JSON.parse(read(DATA + '/config.json')));
if (!/^[a-f0-9]{64}$/.test(C.policy_sha256)) {
  throw new Error('Invalid policy digest');
}
if (!C.protected_hashes || !C.protected_hashes['/etc/passwd'] || !C.protected_hashes['/usr/share/sdbd/public.pem']) {
  throw new Error('Protected-file preflight guards required');
}

const agent = createAgent(C);
let applying = false;
let submitted = false;
let policyResult = null;
let boot = 'unavailable';
let uptime = 0;
let apiBusy = false;
let maintenanceBusy = false;
let lastInspect = 0;
let inspections = 0;
let repairs = 0;
let inspectionResult = null;

try {
  boot = read('/proc/sys/kernel/random/boot_id').toString().trim();
} catch (_) {}

const wire = script => 'printf %s ' + Buffer.from(script).toString('base64') + ' | base64 -d | /bin/bash';

function applyScript() {
  return (
    'set -eu\n' +
    'test "$(id -u)" = 0\n' +
    'printf System > /proc/self/attr/current\n' +
    'test "$(sha256sum ' + POLICY_SCRIPT + ' | cut -d " " -f 1)" = ' + C.policy_sha256 + '\n' +
    "sqlite3 -bail /opt/dbspace/.pkgmgr_parser.db <<'OWN'\n" +
    '.timeout 15000\n' +
    'BEGIN IMMEDIATE;\n' +
    'CREATE TEMP TABLE own_guard(ok INTEGER CHECK(ok=1));\n' +
    "INSERT INTO own_guard SELECT count(*)=1 FROM package_app_info WHERE app_id='TizenGuard.Service' AND package='TizenGuard' AND app_disable='false' AND app_onboot IN ('false','true') AND app_autorestart IN ('false','true');\n" +
    "UPDATE package_app_info SET app_onboot='true',app_autorestart='true' WHERE app_id='TizenGuard.Service' AND package='TizenGuard';\n" +
    'DROP TABLE own_guard;\n' +
    'COMMIT;\n' +
    'OWN\n' +
    '. ' + POLICY_SCRIPT + '\n' +
    'mkdir -p /run/tizenguard\n' +
    'cat /proc/sys/kernel/random/boot_id > ' + APPLIED_MARKER + '\n'
  );
}

async function apply() {
  if (applying || submitted || !agent.status().connected) return;
  applying = true;
  submitted = true; // Never replay an uncertain mutation in this service lifetime.
  try {
    policyResult = await agent.execute(wire(applyScript()), 60000);
  } catch (e) {
    policyResult = { uncertain: true, error: String(e.message).slice(0, 180) };
  } finally {
    applying = false;
    lastInspect = Date.now();
    if (!apiBusy) agent.stop();
  }
}

async function maintain() {
  if (
    apiBusy ||
    maintenanceBusy ||
    applying ||
    !C.enabled ||
    C.apply_policy !== true ||
    !policyResult ||
    policyResult.exit_code !== 0 ||
    policyResult.timed_out ||
    policyResult.uncertain ||
    repairs >= 3 ||
    Date.now() - lastInspect < 120000
  ) {
    return;
  }
  if (!agent.status().connected) {
    agent.start();
    return;
  }
  maintenanceBusy = true;
  lastInspect = Date.now();
  try {
    const r = await agent.execute(wire(read(__dirname + '/check-policy.sh').toString()), 6000);
    inspections++;
    inspectionResult = { exit_code: r.exit_code, timed_out: r.timed_out };
    // Only a completed read-only drift check after a confirmed successful apply
    // permits another idempotent repair. An uncertain mutation is never retried.
    if (r.exit_code === 3 && !r.timed_out) {
      repairs++;
      submitted = false;
      await apply();
    }
  } catch (_) {
    inspectionResult = { error: 'Read-only inspection unavailable' };
  } finally {
    maintenanceBusy = false;
    if (!apiBusy) agent.stop();
  }
}

function status() {
  return {
    schema: 1,
    version: '1.0.0',
    boot,
    uptime,
    enabled: C.enabled,
    apply_policy: C.apply_policy === true,
    root: agent.status(),
    policy_submitted: submitted,
    policy_busy: applying,
    policy_result: policyResult,
    policy_checks: inspections,
    policy_repairs: repairs,
    inspection_result: inspectionResult
  };
}

function save() {
  atomic(DATA + '/config.json', C);
}

const server = https.createServer(
  {
    key: read(DATA + '/server-key.pem'),
    cert: read(DATA + '/server.pem'),
    ca: read(DATA + '/client.pem'),
    requestCert: true,
    rejectUnauthorized: true,
    minVersion: 'TLSv1.2'
  },
  async (req, res) => {
    const reply = (s, v) => {
      res.writeHead(s, {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-store',
        Connection: 'close'
      });
      res.end(JSON.stringify(v));
    };
    const cert = req.socket.getPeerCertificate();
    if (!req.socket.authorized || !cert.raw || hash(cert.raw) !== C.client_sha256 || req.headers.origin) {
      reply(403, { error: 'Owner certificate required' });
      return;
    }
    if (req.method === 'GET' && req.url === '/v1/status') {
      reply(200, status());
      return;
    }
    if (req.method !== 'POST' || !['/v1/enable', '/v1/apply', '/v1/disable', '/v1/restore-sdk', '/v1/reboot'].includes(req.url)) {
      reply(404, { error: 'Unknown operation' });
      return;
    }
    if (apiBusy) {
      reply(409, { error: 'Another owner operation is in progress' });
      return;
    }
    apiBusy = true;
    try {
      let chunks = [];
      let bytes = 0;
      for await (const part of req) {
        bytes += part.length;
        if (bytes > 128) throw new Error('Oversized request');
        chunks.push(part);
      }
      const value = JSON.parse(Buffer.concat(chunks).toString() || '{}');
      if (!value || Array.isArray(value) || Object.keys(value).length) {
        throw new Error('This fixed operation takes no arguments');
      }
      if (req.url === '/v1/enable') {
        C.enabled = true;
        save();
        agent.start();
        reply(200, { enabled: true });
        return;
      }
      if (req.url === '/v1/disable') {
        if (applying || maintenanceBusy) throw new Error('Policy in progress');
        C.enabled = false;
        save();
        agent.stop();
        reply(200, { enabled: false });
        return;
      }
      if (req.url === '/v1/apply') {
        if (applying || submitted) throw new Error('Inspect existing result before another mutation');
        if (!agent.status().connected) throw new Error('Root not ready');
        C.apply_policy = true;
        save();
        await apply();
        reply(200, status());
        return;
      }
      if (applying || maintenanceBusy) {
        throw new Error('Policy in progress');
      }
      if (!agent.status().connected) {
        agent.start();
        const until = Date.now() + 20000;
        while (!agent.status().connected && Date.now() < until) {
          await new Promise(r => setTimeout(r, 200));
        }
        if (!agent.status().connected) throw new Error('Root not ready');
      }
      if (req.url === '/v1/reboot') {
        if (!policyResult || policyResult.exit_code !== 0 || policyResult.timed_out) {
          throw new Error('A successful policy apply is required first');
        }
        const unit = 'tizenguard-reboot-' + crypto.randomBytes(6).toString('hex');
        const script =
          'set -eu\n' +
          'printf System > /proc/self/attr/current\n' +
          'systemd-run --unit=' +
          unit +
          ' --on-active=10s --timer-property=AccuracySec=1s -p Type=oneshot -p User=0 -p Group=0 -p SmackProcessLabel=System --setenv=DBUS_SYSTEM_BUS_ADDRESS=kernel:path=/sys/fs/kdbus/0-system/bus /usr/bin/busctl --timeout=5 --system call org.tizen.system.deviced /Org/Tizen/System/DeviceD/Power org.tizen.system.deviced.power Reboot s "TizenGuard boot verification"\n';
        const r = await agent.execute(wire(script), 15000);
        if (r.exit_code !== 0 || r.timed_out) {
          throw new Error('Reboot scheduling unconfirmed');
        }
        reply(200, { reboot_scheduled: true, result: r });
        return;
      }
      if (!C.sdk_host_ip) {
        throw new Error('sdk_host_ip is not configured');
      }
      C.enabled = false;
      save();
      const returnUnit = 'tizenguard-sdk-return-' + crypto.randomBytes(6).toString('hex');
      const script =
        'set -eu\n' +
        'printf System > /proc/self/attr/current\n' +
        '/usr/bin/dotnet ' + RECOVERY_DLL + ' set 127.0.0.1 ' + C.sdk_host_ip + ' 0\n' +
        'systemd-run --unit=' +
        returnUnit +
        ' --on-active=10s --timer-property=AccuracySec=1s -p Type=oneshot -p SmackProcessLabel=System /bin/systemctl restart sdbd.service\n';
      const result = await agent.execute(wire(script), 15000);
      if (result.exit_code !== 0 || result.timed_out) {
        throw new Error('SDK restoration unconfirmed');
      }
      agent.stop();
      reply(200, { sdk_restore: result });
    } catch (e) {
      reply(409, { error: String(e.message).slice(0, 200) });
    } finally {
      apiBusy = false;
    }
  }
);

server.timeout = 75000;
server.headersTimeout = 10000;
server.maxHeadersCount = 20;
server.maxConnections = 6;
server.on('clientError', (_, s) => s.destroy());
server.on('tlsClientError', () => {});
server.on('error', () => agent.stop());

server.listen(C.port, '0.0.0.0', () => {
  if (C.enabled && Number(read('/proc/uptime').toString().split(' ')[0]) >= 180) {
    agent.start();
  }
});

const tick = setInterval(() => {
  try {
    uptime = Number(read('/proc/uptime').toString().split(' ')[0]);
  } catch (_) {}
  if (!apiBusy && C.enabled && C.apply_policy === true && uptime >= 180 && !submitted) {
    agent.start();
    apply();
  } else if (uptime < 600) {
    maintain();
  }
  if (uptime >= 600 && !apiBusy && !applying && !maintenanceBusy && submitted && agent.status().connected) {
    agent.stop();
  }
}, 5000);

function stop() {
  clearInterval(tick);
  agent.stop();
  server.close();
}

process.on('SIGTERM', stop);
process.on('SIGINT', stop);
