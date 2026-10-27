'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const hash = data => crypto.createHash('sha256').update(data).digest('hex');

function read(file, limit = 65536) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > limit) {
    throw new Error('Invalid configuration file');
  }
  return fs.readFileSync(file);
}

function atomic(file, value) {
  const tmp = file + '.new-' + crypto.randomBytes(8).toString('hex');
  const fd = fs.openSync(tmp, 'wx', 0o600);
  try {
    fs.writeFileSync(fd, JSON.stringify(value));
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(tmp, file);
  const parent = fs.openSync(path.dirname(file), 'r');
  try {
    fs.fsyncSync(parent);
  } finally {
    fs.closeSync(parent);
  }
}

function isValidIPv4(ip) {
  if (typeof ip !== 'string' || !/^(\d{1,3}\.){3}\d{1,3}$/.test(ip) || ip === '0.0.0.0') {
    return false;
  }
  return ip.split('.').every(part => {
    const n = Number(part);
    return Number.isInteger(n) && n >= 0 && n <= 255 && String(n) === part;
  });
}

function config(data) {
  if (
    !data ||
    data.schema !== 1 ||
    !['qn90a', 's90d'].includes(data.device) ||
    typeof data.enabled !== 'boolean' ||
    !Number.isInteger(data.port) ||
    data.port < 1024 ||
    data.port > 65535
  ) {
    throw new Error('Invalid agent configuration');
  }
  if (!/^[a-f0-9]{64}$/.test(data.client_sha256) || !data.firmware || !data.hashes || !Object.keys(data.hashes).length) {
    throw new Error('Missing identity guards');
  }
  for (const p of Object.keys(data.hashes)) {
    if (!['/usr/bin/dotnet', '/usr/bin/dotnet-launcher', '/usr/sbin/sdbd-tarlauncher'].includes(p) || !/^[a-f0-9]{64}$/.test(data.hashes[p])) {
      throw new Error('Invalid firmware guard');
    }
  }
  if (!data.hashes['/usr/bin/dotnet'] || !data.hashes['/usr/sbin/sdbd-tarlauncher']) {
    throw new Error('Missing launcher guards');
  }
  if (data.protected_hashes) {
    for (const p of Object.keys(data.protected_hashes)) {
      if (!['/etc/passwd', '/usr/share/sdbd/public.pem'].includes(p) || !/^[a-f0-9]{64}$/.test(data.protected_hashes[p])) {
        throw new Error('Invalid protected-file guard');
      }
    }
  }
  if (data.sdk_host_ip !== undefined && !isValidIPv4(data.sdk_host_ip)) {
    throw new Error('Invalid sdk_host_ip');
  }
  return data;
}

function verifyFirmware(c) {
  if (!read('/etc/prd_info.ini').toString().split(/\r?\n/).includes('Version=' + c.firmware + ';')) {
    throw new Error('Firmware mismatch');
  }
}

function sdkRuntimeGuard(c) {
  config(c);
  // Check the pinned SHA-256 digests under SDK UID before executing dotnet or the archive launcher.
  const guards = Object.assign({}, c.hashes, c.protected_hashes || {});
  return (
    Object.keys(guards)
      .sort()
      .map(
        p =>
          "test \"$(sha256sum '" +
          p +
          "' | cut -d ' ' -f 1)\" = '" +
          guards[p] +
          "' || { echo 'Preflight hash mismatch: " +
          p +
          "'; exit 74; }"
      )
      .join('\n') + '\n'
  );
}

function validateRequest(v) {
  if (
    !v ||
    Object.keys(v).some(k => !['id', 'command', 'timeout_ms'].includes(k)) ||
    !/^[-a-zA-Z0-9]{16,64}$/.test(v.id) ||
    typeof v.command !== 'string' ||
    !v.command.trim() ||
    Buffer.byteLength(v.command) > 16384 ||
    v.command.includes('\0') ||
    !Number.isInteger(v.timeout_ms) ||
    v.timeout_ms < 100 ||
    v.timeout_ms > 25000
  ) {
    throw new Error('Invalid command request');
  }
  return v;
}

class Journal {
  constructor(file) {
    this.file = file;
    this.archiveDir = file + '.archives';
    this.failed = false;
    this.seen = new Map();
    this.rows = this.present(file) ? JSON.parse(read(file, 262144)) : [];
    this.validate(this.rows);

    const parent = path.dirname(file);
    const prefix = path.basename(file, '.json') + '.archive-';
    for (const name of fs.readdirSync(parent)) {
      if (name.startsWith(prefix) && name.endsWith('.json')) {
        this.remember(JSON.parse(read(path.join(parent, name), 262144)));
      }
    }
    if (this.present(this.archiveDir)) {
      this.checkArchiveDir();
      for (const name of fs.readdirSync(this.archiveDir)) {
        if (/^[a-f0-9]{64}\.json\.new-[a-f0-9]{16}$/.test(name)) {
          continue; // interrupted pre-rename write; active journal remains authoritative
        }
        if (!/^[a-f0-9]{64}\.json$/.test(name)) {
          throw new Error('Unexpected journal archive file');
        }
        const bytes = read(path.join(this.archiveDir, name), 262144);
        if (hash(bytes) !== name.slice(0, 64)) {
          throw new Error('Journal archive hash mismatch');
        }
        this.remember(JSON.parse(bytes));
      }
    }
    this.remember(this.rows);
  }

  validate(rows) {
    if (!Array.isArray(rows) || rows.length > 1000) {
      throw new Error('Invalid command journal');
    }
    const ids = new Set();
    for (const r of rows) {
      if (
        !r ||
        !/^[-a-zA-Z0-9]{16,64}$/.test(r.id) ||
        !/^[a-f0-9]{64}$/.test(r.sha256) ||
        !['submitted', 'completed'].includes(r.state) ||
        !Number.isFinite(r.at) ||
        ids.has(r.id)
      ) {
        throw new Error('Invalid command journal entry');
      }
      ids.add(r.id);
    }
  }

  remember(rows) {
    this.validate(rows);
    for (const r of rows) {
      if (this.seen.has(r.id) && this.seen.get(r.id) !== r.sha256) {
        throw new Error('Conflicting archived request');
      }
      this.seen.set(r.id, r.sha256);
    }
  }

  present(file) {
    try {
      fs.lstatSync(file);
      return true;
    } catch (e) {
      if (e.code === 'ENOENT') return false;
      throw e;
    }
  }

  checkArchiveDir() {
    const s = fs.lstatSync(this.archiveDir);
    if (!s.isDirectory() || s.isSymbolicLink()) {
      throw new Error('Invalid journal archive directory');
    }
  }

  digest() {
    return hash(JSON.stringify(this.rows));
  }

  save(rows) {
    try {
      atomic(this.file, rows);
      this.rows = rows;
    } catch (e) {
      this.failed = true;
      throw e;
    }
  }

  archive(expected) {
    if (this.failed) {
      throw new Error('Journal storage failed; restart after diagnosis');
    }
    if (expected !== undefined && expected !== this.digest()) {
      throw new Error('Journal changed; inspect before archiving');
    }
    const completed = this.rows.filter(r => r.state === 'completed');
    const recent = new Set(completed.slice(-100).map(r => r.id));
    const retained = this.rows.filter(r => r.state !== 'completed' || recent.has(r.id));
    if (retained.length === this.rows.length) {
      return { archived_entries: 0, retained_entries: this.rows.length, sha256: this.digest() };
    }
    const bytes = Buffer.from(JSON.stringify(this.rows));
    const digest = hash(bytes);
    const destination = path.join(this.archiveDir, digest + '.json');
    try {
      try {
        fs.mkdirSync(this.archiveDir, 0o700);
      } catch (e) {
        if (e.code !== 'EEXIST') throw e;
      }
      this.checkArchiveDir();
      if (this.present(destination)) {
        if (!read(destination, 262144).equals(bytes)) {
          throw new Error('Journal archive conflict');
        }
      } else {
        atomic(destination, this.rows);
      }
      const parent = fs.openSync(path.dirname(this.archiveDir), 'r');
      try {
        fs.fsyncSync(parent);
      } finally {
        fs.closeSync(parent);
      }
      if (!read(destination, 262144).equals(bytes)) {
        throw new Error('Journal archive verification failed');
      }
      const removed = this.rows.length - retained.length;
      this.save(retained);
      return {
        archived_entries: removed,
        retained_entries: retained.length,
        archive_sha256: digest,
        sha256: this.digest()
      };
    } catch (e) {
      this.failed = true;
      throw e;
    }
  }

  begin(v) {
    validateRequest(v);
    if (this.failed) {
      throw new Error('Journal storage failed; restart after diagnosis');
    }
    if (this.seen.has(v.id)) {
      throw new Error('Request already submitted; inspect outcome, do not replay');
    }
    if (this.rows.length >= 1000) {
      this.archive();
    }
    if (this.rows.length >= 1000) {
      throw new Error('Command journal full of unfinished requests; inspect outcomes');
    }
    this.save(
      this.rows.concat([
        {
          id: v.id,
          sha256: hash(v.command),
          state: 'submitted',
          at: Date.now()
        }
      ])
    );
    this.seen.set(v.id, hash(v.command));
  }

  finish(id, result) {
    if (this.failed) {
      throw new Error('Journal storage failed; restart after diagnosis');
    }
    if (!this.rows.some(r => r.id === id && r.state === 'submitted')) {
      throw new Error('Unknown pending request');
    }
    this.save(
      this.rows.map(r =>
        r.id === id
          ? Object.assign({}, r, {
              state: 'completed',
              exit_code: result.exit_code,
              timed_out: result.timed_out
            })
          : r
      )
    );
  }
}

module.exports = {
  read,
  atomic,
  hash,
  config,
  verifyFirmware,
  sdkRuntimeGuard,
  validateRequest,
  Journal
};
