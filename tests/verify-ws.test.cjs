'use strict';

// Exercises tools/verify-ws.mjs against real sockets: a self-signed HTTPS
// server that accepts or rejects the upgrade, exactly like DSH does.
const assert = require('node:assert/strict');
const { execFile, execFileSync } = require('node:child_process');
const https = require('node:https');
const { mkdtempSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { after, before, test } = require('node:test');

const script = join(__dirname, '..', 'tools', 'verify-ws.mjs');
let server;
let port;

function selfSignedPair() {
  // openssl keeps the test independent of any bundled certificate fixtures.
  const dir = mkdtempSync(join(tmpdir(), 'dsh-ws-'));
  const key = join(dir, 'key.pem');
  const cert = join(dir, 'cert.pem');
  execFileSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-sha256',
    '-keyout', key, '-out', cert, '-subj', '/CN=127.0.0.1',
    '-addext', 'subjectAltName=IP:127.0.0.1',
  ], { stdio: 'ignore' });
  return { key, cert };
}

// Must be async: the mock server lives in this process and has to keep
// serving while the verifier connects to it.
function run(args) {
  return new Promise((resolve) => {
    execFile(process.execPath, [script, ...args], { encoding: 'utf8' }, (error, stdout, stderr) => {
      resolve({ code: error ? (error.code ?? 1) : 0, output: String(stdout) + String(stderr) });
    });
  });
}

before(async () => {
  const { key, cert } = selfSignedPair();
  server = https.createServer({ key: require('node:fs').readFileSync(key), cert: require('node:fs').readFileSync(cert) });
  // DSH rejects unauthenticated upgrades with 401 and accepts valid cookies.
  server.on('upgrade', (req, socket) => {
    // RFC 6455: the key must be 16 random bytes, base64 encoded. DSH answers
    // 400 otherwise, so the mock must be just as strict.
    const key = Buffer.from(String(req.headers['sec-websocket-key'] || ''), 'base64');
    if (key.length !== 16) {
      socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
      return;
    }
    if (!/dsh-auth=/.test(req.headers.cookie || '')) {
      socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      return;
    }
    socket.end('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n');
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  port = server.address().port;
});

after(() => server.close());

function jarWith(value) {
  const jar = join(mkdtempSync(join(tmpdir(), 'dsh-jar-')), 'cookies.txt');
  // curl marks HttpOnly cookies with a "#HttpOnly_" prefix; the verifier must
  // still read them or every authenticated upgrade looks unauthenticated.
  writeFileSync(jar, `#HttpOnly_127.0.0.1\tFALSE\t/\tTRUE\t0\tdsh-auth\t${value}\n`);
  return jar;
}

test('accepts a 101 upgrade that carries an authenticated cookie', async () => {
  const jar = jarWith('sample-redacted');
  const { code, output } = await run(['--url', `https://127.0.0.1:${port}/api/remote.mux`, '--cookie-jar', jar, '--insecure']);
  assert.equal(code, 0, output);
  assert.match(output, /101/);
});

test('fails when the upgrade is rejected with 401', async () => {
  const { code } = await run(['--url', `https://127.0.0.1:${port}/api/remote.mux`, '--insecure']);
  assert.equal(code, 1);
});

test('fails closed when the self-signed certificate is not waived', async () => {
  const jar = jarWith('sample-redacted');
  const { code } = await run(['--url', `https://127.0.0.1:${port}/api/remote.mux`, '--cookie-jar', jar]);
  assert.equal(code, 1);
});

test('never prints the cookie value on success or failure', async () => {
  const jar = jarWith('super-secret-value');
  for (const args of [
    ['--url', `https://127.0.0.1:${port}/api/remote.mux`, '--cookie-jar', jar, '--insecure'],
    ['--url', `https://127.0.0.1:${port}/api/remote.mux`, '--cookie-jar', jar],
  ]) {
    const { output } = await run(args);
    assert.ok(!output.includes('super-secret-value'), 'cookie value leaked into output');
  }
});
