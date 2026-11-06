#!/usr/bin/env node
'use strict';

const http = require('node:http');

function hostAllowed(value, trustedHost) {
  if (typeof value !== 'string' || !value) return false;
  try {
    return new URL("http://" + value).hostname.toLowerCase() === trustedHost.toLowerCase();
  } catch {
    return false;
  }
}

function secureCookies(headers, enabled = true) {
  if (!enabled || !headers['set-cookie']) return headers;
  const cookies = Array.isArray(headers['set-cookie']) ? headers['set-cookie'] : [headers['set-cookie']];
  return {
    ...headers,
    'set-cookie': cookies.map((cookie) => /(?:^|;)\s*secure\s*(?:;|$)/i.test(cookie) ? cookie : `${cookie}; Secure`),
  };
}

function createProxyServer({ upstreamPort, trustedHost, upstreamHost = '127.0.0.1', secureCookiesEnabled = true }) {
  if (!Number.isInteger(upstreamPort) || upstreamPort < 1 || upstreamPort > 65535) throw new Error('invalid upstream port');
  if (!trustedHost) throw new Error('trusted host is required');

  const server = http.createServer((incoming, outgoing) => {
    if (!hostAllowed(incoming.headers.host, trustedHost)) {
      outgoing.writeHead(421, { connection: 'close' });
      outgoing.end('Misdirected Request');
      return;
    }
    const headers = {
      ...incoming.headers,
      'x-forwarded-proto': 'https',
      'x-forwarded-host': incoming.headers.host,
    };
    const upstream = http.request({
      host: upstreamHost,
      port: upstreamPort,
      method: incoming.method,
      path: incoming.url,
      headers,
    }, (response) => {
      outgoing.writeHead(response.statusCode || 502, response.statusMessage, secureCookies(response.headers, secureCookiesEnabled));
      response.pipe(outgoing);
    });
    upstream.on('error', () => {
      if (!outgoing.headersSent) outgoing.writeHead(502, { connection: 'close' });
      outgoing.end('Bad Gateway');
    });
    incoming.on('aborted', () => upstream.destroy());
    outgoing.on('close', () => { if (!outgoing.writableEnded) upstream.destroy(); });
    incoming.pipe(upstream);
  });

  server.on('upgrade', (incoming, clientSocket, head) => {
    if (!hostAllowed(incoming.headers.host, trustedHost)) {
      clientSocket.end('HTTP/1.1 421 Misdirected Request\r\nConnection: close\r\n\r\n');
      return;
    }
    const headers = {
      ...incoming.headers,
      'x-forwarded-proto': 'https',
      'x-forwarded-host': incoming.headers.host,
    };
    const upstream = http.request({
      host: upstreamHost,
      port: upstreamPort,
      method: incoming.method,
      path: incoming.url,
      headers,
    });
    upstream.on('upgrade', (response, upstreamSocket, upstreamHead) => {
      clientSocket.write(`HTTP/1.1 ${response.statusCode} ${response.statusMessage}\r\n`);
      for (let i = 0; i < response.rawHeaders.length; i += 2) {
        clientSocket.write(`${response.rawHeaders[i]}: ${response.rawHeaders[i + 1]}\r\n`);
      }
      clientSocket.write('\r\n');
      if (upstreamHead.length) clientSocket.write(upstreamHead);
      if (head.length) upstreamSocket.write(head);
      upstreamSocket.pipe(clientSocket);
      clientSocket.pipe(upstreamSocket);
      clientSocket.on('error', () => upstreamSocket.destroy());
      upstreamSocket.on('error', () => clientSocket.destroy());
    });
    upstream.on('response', (response) => {
      clientSocket.end(`HTTP/1.1 ${response.statusCode} ${response.statusMessage}\r\nConnection: close\r\n\r\n`);
    });
    upstream.on('error', () => clientSocket.destroy());
    upstream.end();
  });

  return server;
}

module.exports = { createProxyServer, hostAllowed, secureCookies };

if (require.main === module) {
  const port = Number(process.env.DSH_PROXY_PORT || 3081);
  const upstreamPort = Number(process.env.DSH_PORT || 3080);
  const trustedHost = process.env.DSH_TRUSTED_HOST || '';
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('invalid proxy port');
  const server = createProxyServer({ upstreamPort, trustedHost, secureCookiesEnabled: process.env.DSH_PROXY_SECURE_COOKIES !== 'no' });
  server.listen(port, '127.0.0.1', () => console.log(`DSH HTTPS proxy listening on 127.0.0.1:${port}`));
}
