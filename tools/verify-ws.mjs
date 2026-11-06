#!/usr/bin/env node
/**
 * Verify a DSH WebSocket upgrade returns 101 without printing any credential.
 *
 * Usage: verify-ws.mjs --url https://host/api/remote.mux [--cookie-jar FILE]
 *                      [--insecure] [--expect 101]
 * Exit status is 0 only when the upgrade handshake is accepted.
 */
import { readFileSync } from 'node:fs';
import net from 'node:net';
import tls from 'node:tls';

const args = { url: '', cookieJar: '', insecure: false, expect: '101', host: '' };
for (let i = 2; i < process.argv.length; i += 1) {
  const flag = process.argv[i];
  if (flag === '--url') args.url = process.argv[++i] ?? '';
  else if (flag === '--cookie-jar') args.cookieJar = process.argv[++i] ?? '';
  else if (flag === '--insecure') args.insecure = true;
  else if (flag === '--host') args.host = process.argv[++i] ?? '';
  else if (flag === '--expect') args.expect = process.argv[++i] ?? '';
  else if (flag === '--help') {
    console.log('usage: verify-ws.mjs --url URL [--cookie-jar FILE] [--host NAME] [--insecure] [--expect 101]');
    process.exit(0);
  } else {
    console.error(`verify-ws: unknown option ${flag}`);
    process.exit(64);
  }
}
if (!args.url) {
  console.error('verify-ws: --url is required');
  process.exit(64);
}

/** Read a Netscape cookie jar without ever echoing its values. */
function cookieHeader(file) {
  let text = '';
  try {
    text = readFileSync(file, 'utf8');
  } catch {
    return '';
  }
  const pairs = [];
  for (const line of text.split('\n')) {
    if (!line || line.startsWith('#')) continue;
    const fields = line.split('\t');
    if (fields.length < 7) continue;
    pairs.push(`${fields[5]}=${fields[6]}`);
  }
  return pairs.join('; ');
}

const target = new URL(args.url);
const cookie = args.cookieJar ? cookieHeader(args.cookieJar) : '';
const headers = {
  Connection: 'Upgrade',
  Upgrade: 'websocket',
  'Sec-WebSocket-Version': '13',
  'Sec-WebSocket-Key': Buffer.from('dsh-deploy-verify').toString('base64'),
  Host: args.host || target.host,
};
if (cookie) headers.Cookie = cookie;

const isHttps = target.protocol === 'https:';
const port = Number(target.port || (isHttps ? 443 : 80));
const timeoutMs = 10000;

const socket = isHttps
  ? tls.connect({ host: target.hostname, port, servername: target.hostname, rejectUnauthorized: !args.insecure })
  : net.connect({ host: target.hostname, port });

let raw = '';
const finish = (code, message) => {
  socket.destroy();
  if (message) console.error(`verify-ws: ${message}`);
  process.exit(code);
};

const timer = setTimeout(() => finish(1, `upgrade handshake timed out after ${timeoutMs}ms`), timeoutMs);
socket.setTimeout(timeoutMs);

socket.once(isHttps ? 'secureConnect' : 'connect', () => {
  const lines = [`GET ${target.pathname}${target.search} HTTP/1.1`];
  for (const [key, value] of Object.entries(headers)) lines.push(`${key}: ${value}`);
  socket.write(`${lines.join('\r\n')}\r\n\r\n`);
});

socket.on('data', (chunk) => {
  raw += chunk.toString('latin1');
  const end = raw.indexOf('\r\n');
  if (end === -1) return;
  const status = raw.slice(0, end);
  const match = /^HTTP\/\d(?:\.\d)?\s+(\d{3})/.exec(status);
  clearTimeout(timer);
  if (!match) return finish(1, 'malformed HTTP response to upgrade request');
  const code = match[1];
  if (code !== args.expect) {
    console.log(`status=${code} expected=${args.expect}`);
    return finish(1, `upgrade rejected with HTTP ${code}, expected ${args.expect}`);
  }
  console.log(`status=${code} upgrade=accepted`);
  finish(0);
});

socket.on('error', (error) => {
  clearTimeout(timer);
  finish(1, `socket error: ${error.message}`);
});

socket.on('timeout', () => {
  clearTimeout(timer);
  finish(1, 'socket timeout');
});

