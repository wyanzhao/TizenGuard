'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const https = require('node:https');
const os = require('node:os');
const path = require('node:path');
const tls = require('node:tls');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');

const policy = require('../widget/service/policy');

function generateTestCerts(dir) {
  const extFile = path.join(dir, 'ext.cnf');
  fs.writeFileSync(
    extFile,
    '[v3_req]\nbasicConstraints = CA:FALSE\nkeyUsage = digitalSignature, keyEncipherment\nextendedKeyUsage = serverAuth\nsubjectAltName = IP:127.0.0.1\n'
  );
  execFileSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', path.join(dir, 'server-key.pem'),
    '-out', path.join(dir, 'server.pem'),
    '-days', '1', '-subj', '/CN=127.0.0.1',
    '-extensions', 'v3_req', '-config', extFile,
  ], { stdio: 'ignore' });
  execFileSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', path.join(dir, 'client-key.pem'),
    '-out', path.join(dir, 'client.pem'),
    '-days', '1', '-subj', '/CN=tizenguard-owner',
  ], { stdio: 'ignore' });
  const der = execFileSync('openssl', [
    'x509', '-in', path.join(dir, 'client.pem'), '-outform', 'DER',
  ]);
  return crypto.createHash('sha256').update(der).digest('hex');
}

test('TizenGuard.Service mTLS API enforces certificate pinning, allowlist, and configured sdk_host_ip', async () => {
  const credDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tizenguard-mtls-'));
  const dataPath = '/opt/usr/home/owner/apps_rw/TizenGuard/data';
  const clientSha256 = generateTestCerts(credDir);

  const cfg = {
    schema: 1,
    device: 'qn90a',
    enabled: true,
    apply_policy: true,
    port: 28443,
    firmware: 'T-NKM2AKUC-2310.0',
    sdk_host_ip: '198.51.100.42',
    client_sha256: clientSha256,
    policy_sha256: 'a'.repeat(64),
    hashes: {
      '/usr/bin/dotnet': 'b'.repeat(64),
      '/usr/sbin/sdbd-tarlauncher': 'c'.repeat(64),
    },
    protected_hashes: {
      '/etc/passwd': 'd'.repeat(64),
      '/usr/share/sdbd/public.pem': 'e'.repeat(64),
    },
  };

  let server;
  let started = false;
  let connected = false;
  const executedCommands = [];

  const agent = {
    status: () => ({ connected }),
    start: () => {
      started = true;
    },
    stop: () => {
      connected = false;
    },
    execute: async (cmd) => {
      executedCommands.push(cmd);
      return { exit_code: 0, timed_out: false, stdout: 'OK\n', stderr: '' };
    },
  };

  const serviceDir = path.resolve(__dirname, '../widget/service');
  const mainSource = fs.readFileSync(path.join(serviceDir, 'main.js'), 'utf8');

  vm.runInNewContext(mainSource, {
    __dirname: serviceDir,
    Buffer,
    console,
    process: { on() {} },
    setInterval: () => 1,
    clearInterval() {},
    setTimeout,
    require(name) {
      if (name === './agent') return { createAgent: () => agent };
      if (name === './policy') {
        return {
          ...policy,
          atomic() {},
          read(p) {
            if (p === dataPath + '/config.json') {
              return Buffer.from(JSON.stringify(cfg));
            }
            if (p.startsWith(dataPath + '/')) {
              return fs.readFileSync(path.join(credDir, path.basename(p)));
            }
            if (p === '/proc/sys/kernel/random/boot_id') {
              return Buffer.from('fixture-boot-id');
            }
            if (p === '/proc/uptime') {
              return Buffer.from('100 50');
            }
            return fs.readFileSync(p);
          },
        };
      }
      if (name === 'https') {
        return {
          createServer(options, handler) {
            server = https.createServer(options, handler);
            const origListen = server.listen.bind(server);
            server.listen = (_port, _host, cb) => origListen(0, '127.0.0.1', cb);
            return server;
          },
        };
      }
      return require(name);
    },
  });

  if (!server.listening) {
    await new Promise((resolve) => server.once('listening', resolve));
  }
  const boundPort = server.address().port;

  function request(method, urlPath, body, withClientCert = true) {
    return new Promise((resolve, reject) => {
      const options = {
        hostname: '127.0.0.1',
        port: boundPort,
        path: urlPath,
        method,
        ca: fs.readFileSync(path.join(credDir, 'server.pem')),
        checkServerIdentity: (_host, cert) => tls.checkServerIdentity('127.0.0.1', cert),
        headers: { 'Content-Type': 'application/json' },
        rejectUnauthorized: true,
      };
      if (withClientCert) {
        options.cert = fs.readFileSync(path.join(credDir, 'client.pem'));
        options.key = fs.readFileSync(path.join(credDir, 'client-key.pem'));
      }
      const req = https.request(options, (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () =>
          resolve({
            status: res.statusCode,
            value: JSON.parse(Buffer.concat(chunks).toString('utf8')),
          })
        );
      });
      req.on('error', reject);
      req.end(body);
    });
  }

  try {
    // 1. Enrolled client cert succeeds on /v1/status
    const st = await request('GET', '/v1/status');
    assert.equal(st.status, 200);
    assert.equal(st.value.schema, 1);

    // 2. Missing client cert is rejected at TLS handshake
    await assert.rejects(request('GET', '/v1/status', undefined, false));

    // 3. Generic exec endpoint does not exist
    assert.equal((await request('POST', '/v1/exec', '{}')).status, 404);

    // 4. Extra request body keys are rejected
    assert.equal((await request('POST', '/v1/enable', '{"command":"id"}')).status, 409);
    assert.equal(started, false);

    // 5. /v1/enable starts agent
    assert.equal((await request('POST', '/v1/enable', '{}')).status, 200);
    assert.equal(started, true);

    // 6. /v1/apply when root session is not ready returns 409 without executing commands
    assert.equal((await request('POST', '/v1/apply', '{}')).status, 409);
    assert.equal(executedCommands.length, 0);

    // 7. When root session is connected, /v1/restore-sdk uses configured sdk_host_ip
    connected = true;
    const restored = await request('POST', '/v1/restore-sdk', '{}');
    assert.equal(restored.status, 200);
    assert.equal(executedCommands.length, 1);
    const decoded = Buffer.from(
      executedCommands[0].split(' ')[2],
      'base64'
    ).toString('utf8');
    assert.match(decoded, /SdkHostRecovery\.dll set 127\.0\.0\.1 198\.51\.100\.42 0/);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(credDir, { recursive: true, force: true });
  }
});
