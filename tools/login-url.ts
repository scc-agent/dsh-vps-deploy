#!/usr/bin/env node
/** Read only the current systemd process' startup URL. */
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

export function parseArgs(argv: string[]) {
  const args = { unit: 'dsh-web.service', publicUrl: '' };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--unit') args.unit = argv[++i] ?? '';
    else if (argv[i] === '--public-url') args.publicUrl = argv[++i] ?? '';
    else if (argv[i] === '--help') {
      console.log('usage: login-url.ts [--unit dsh-web.service] [--public-url https://host/path/]');
      process.exit(0);
    } else throw new Error(`unknown option: ${argv[i]}`);
  }
  if (!args.unit || /[^A-Za-z0-9_.@:-]/.test(args.unit)) throw new Error('invalid unit name');
  return args;
}

function command(file: string, args: string[]) {
  return execFileSync(file, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

const procRoot = process.env.DSH_PROC_ROOT ?? '/proc';

function currentProcess(unit: string) {
  const pid = command('systemctl', ['show', '--value', '--property=MainPID', unit]);
  if (!/^\d+$/.test(pid) || pid === '0') throw new Error(`${unit} has no active MainPID`);
  const cmdline = readFileSync(`${procRoot}/${pid}/cmdline`, 'utf8').split('\0').filter(Boolean);
  if (!cmdline.includes('--profile') || cmdline[cmdline.indexOf('--profile') + 1] !== 'web') {
    throw new Error(`MainPID ${pid} is not a dsh web process`);
  }
  const activeSince = command('systemctl', ['show', '--value', '--property=ActiveEnterTimestamp', unit]);
  if (!activeSince) throw new Error('systemd did not provide the current start time');
  return { pid, cmdline, activeSince };
}

export function withExternalRoot(authenticatedUrl: string, externalRoot?: string) {
  const tokenUrl = new URL(authenticatedUrl);
  if (!externalRoot) return tokenUrl.toString();
  const root = new URL(externalRoot);
  if (root.protocol !== 'https:' && root.protocol !== 'http:') throw new Error('external URL must use http or https');
  root.search = tokenUrl.search;
  root.hash = '';
  if (!root.pathname.endsWith('/')) root.pathname += '/';
  return root.toString();
}

export function findCurrentUrl(unit: string, activeSince: string) {
  const log = command('journalctl', ['-u', unit, '--since', activeSince, '--no-pager', '--output=cat']);
  const matches = [...log.matchAll(/dsh web:\s+(https?:\/\/[^\s\u001b]+)/g)];
  if (matches.length === 0) throw new Error('no startup credential for the current process start');
  const url = matches.at(-1)?.[1]?.replace(/[\u001b\].,;]+$/, '');
  if (!url) throw new Error('startup credential was empty');
  return url;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    const args = parseArgs(process.argv.slice(2));
    const { activeSince } = currentProcess(args.unit);
    const current = findCurrentUrl(args.unit, activeSince);
    console.log(withExternalRoot(current, args.publicUrl || undefined));
  } catch (error) {
    console.error(`login-url: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  }
}
