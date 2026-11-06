'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const net = require('node:net');
const { after, before, test } = require('node:test');
const { createProxyServer } = require('../bin/dsh-web-proxy.cjs');

let backend;
let proxy;
let proxyPort;
let upstreamPort;
const sockets = new Set();

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      server.removeListener('error', reject);
      resolve(server.address().port);
    });
  });
}

before(async () => {
  backend = http.createServer((req, res) => {
    if (req.url === '/login') {
      res.setHeader('set-cookie', [
        'session=sample; HttpOnly; SameSite=Strict; Path=/',
        'theme=dark; Secure; Path=/',
      ]);
      res.setHeader('x-seen-proto', req.headers['x-forwarded-proto'] || '');
      res.end('ok');
      return;
    }
    res.end('ok');
  });
  backend.on('connection', (socket) => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  backend.on('upgrade', (_req, socket) => {
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: test\r\n\r\nready');
    socket.on('data', (chunk) => socket.write(chunk));
  });
  upstreamPort = await listen(backend);
  proxy = createProxyServer({ upstreamPort, trustedHost: 'dsh.example.test', secureCookiesEnabled: true });
  proxy.on('connection', (socket) => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  proxyPort = await listen(proxy);
});

after(async () => {
  for (const socket of sockets) socket.destroy();
  await Promise.all([backend, proxy].map((server) => new Promise((resolve) => server.close(resolve))));
});

test('adds Secure to every cookie and preserves HTTPS forwarding context', async () => {
  const response = await new Promise((resolve, reject) => {
    http.get({ hostname: '127.0.0.1', port: proxyPort, path: '/login', headers: { host: 'dsh.example.test' } }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString() }));
    }).on('error', reject);
  });
  assert.equal(response.status, 200);
  assert.equal(response.body, 'ok');
  assert.equal(response.headers['x-seen-proto'], 'https');
  assert.match(response.headers['set-cookie'][0], /; Secure$/);
  assert.equal((response.headers['set-cookie'][1].match(/Secure/g) || []).length, 1);
  assert.match(response.headers['set-cookie'][0], /HttpOnly; SameSite=Strict/);
});

test('rejects a Host header outside the configured trusted host', async () => {
  const status = await new Promise((resolve, reject) => {
    http.get({ hostname: '127.0.0.1', port: proxyPort, headers: { host: 'attacker.invalid' } }, (res) => {
      res.resume();
      res.on('end', () => resolve(res.statusCode));
    }).on('error', reject);
  });
  assert.equal(status, 421);
});

test('passes WebSocket upgrade and bidirectional frames', async () => {
  const result = await new Promise((resolve, reject) => {
    const socket = net.connect(proxyPort, '127.0.0.1');
    let received = '';
    let sentPing = false;
    const timeout = setTimeout(() => { socket.destroy(); reject(new Error('websocket proxy timed out: ' + received)); }, 3000);
    socket.on('connect', () => socket.write('GET /ws HTTP/1.1\r\nHost: dsh.example.test\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: sample\r\nSec-WebSocket-Version: 13\r\n\r\n'));
    socket.on('data', (chunk) => {
      received += chunk.toString();
      if (received.includes('ready') && !sentPing) { sentPing = true; socket.write('ping'); }
      if (received.includes('ready') && received.includes('ping')) {
        clearTimeout(timeout);
        socket.destroy();
        resolve(received);
      }
    });
    socket.on('error', reject);
  });
  assert.match(result, /101 Switching Protocols/);
  assert.match(result, /ready/);
  assert.match(result, /ping/);
});
