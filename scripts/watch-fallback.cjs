'use strict';

// Only the global DIRECT interface changes. Proxy interfaces remain in the routing config.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const net = require('node:net');
const crypto = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const execFileAsync = promisify(execFile);

function normalizeConfig(input, baseDirectory = process.cwd()) {
  const config = { pipeName: 'verge-mihomo', intervalSeconds: 5, recoverySamples: 3, ...input };
  for (const field of ['domesticInterface', 'overseasInterface', 'pipeName']) {
    if (typeof config[field] !== 'string' || !config[field].trim()) throw new Error(`Invalid ${field}`);
  }
  if (config.domesticInterface === config.overseasInterface) throw new Error('Interfaces must differ');
  if (!/^[a-zA-Z0-9_.-]+$/.test(config.pipeName)) throw new Error('Invalid pipeName');
  if (!Number.isFinite(config.intervalSeconds) || config.intervalSeconds < 1) throw new Error('Invalid intervalSeconds');
  if (!Number.isInteger(config.recoverySamples) || config.recoverySamples < 1) throw new Error('Invalid recoverySamples');
  for (const field of ['stateFile', 'logFile', 'stopFile']) {
    if (config[field] !== undefined) {
      if (typeof config[field] !== 'string' || !config[field]) throw new Error(`Invalid ${field}`);
      config[field] = path.resolve(baseDirectory, config[field]);
    }
  }
  return config;
}

function createState() {
  return { recoveryCount: 0, fallbackSeen: false, appliedState: null, currentInterface: null, status: 'starting' };
}

function decideState(previous, adapters, config) {
  const ready = name => adapters.some(adapter => adapter.Name === name && adapter.ready === true);
  const domesticReady = ready(config.domesticInterface);
  const overseasReady = ready(config.overseasInterface);
  previous = { ...previous, domesticReady, overseasReady };
  if (!domesticReady && !overseasReady) {
    return { ...previous, recoveryCount: 0, fallbackSeen: true, target: null, status: 'waiting' };
  }
  if (!domesticReady) {
    return { ...previous, recoveryCount: 0, fallbackSeen: true, target: config.overseasInterface, status: 'wifi' };
  }
  // At startup an already healthy cable is used immediately. After a cable outage,
  // require consecutive ready samples, unless Wi-Fi also needs recovery.
  const recoveryCount = previous.fallbackSeen ? previous.recoveryCount + 1 : config.recoverySamples;
  if (previous.fallbackSeen && overseasReady && recoveryCount < config.recoverySamples) {
    return { ...previous, recoveryCount, target: config.overseasInterface, status: 'recovering' };
  }
  return { ...previous, recoveryCount: 0, fallbackSeen: false, target: config.domesticInterface, status: 'split' };
}

async function tick(previous, adapters, config, api) {
  const next = decideState(previous, adapters, config);
  try {
    // Read every round so a GUI profile reload is corrected on the next round.
    const before = await api('GET', '/configs');
    next.currentInterface = before['interface-name'] || '';
    if (next.target === null) return { ...next, changed: false, error: null };
    const changed = before['interface-name'] !== next.target;
    if (changed) {
      // Preserve the refresh request across a lost response: the PATCH may have
      // reached Mihomo even when its acknowledgement or verification times out.
      next.closePending = true;
      await api('PATCH', '/configs', { 'interface-name': next.target });
      const after = await api('GET', '/configs');
      next.currentInterface = after['interface-name'] || '';
      if (after['interface-name'] !== next.target) throw new Error('Interface verification failed');
    }
    // Remember verified routing even if closing old connections needs another attempt.
    const verified = { ...next, appliedState: next.target, changed, error: null };
    if (changed || previous.closePending) {
      try {
        await api('DELETE', '/connections');
      } catch {
        return { ...verified, closePending: true, error: 'Connection refresh failed' };
      }
    }
    return { ...verified, closePending: false };
  } catch (error) {
    return { ...next, appliedState: previous.appliedState, changed: false,
      closePending: next.closePending || false,
      error: error.message === 'Interface verification failed' ? error.message : 'Mihomo API unavailable' };
  }
}

async function queryAdapters(config) {
  const names = Buffer.from(JSON.stringify([config.domesticInterface, config.overseasInterface]), 'utf8').toString('base64');
  const script = `$ErrorActionPreference='Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$names = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${names}')) | ConvertFrom-Json
$data = @(foreach ($name in $names) {
  $nic = Get-NetAdapter | Where-Object { $_.Name -ceq $name } | Select-Object -First 1
  $ready = $false
  if ($nic -and $nic.Status -eq 'Up') {
    $ips = @(Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notmatch '^(169\\.254\\.|127\\.|0\\.)' })
    $routes = @(Get-NetRoute -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -ne '0.0.0.0' })
    $ready = $ips.Count -gt 0 -and $routes.Count -gt 0
  }
  [pscustomobject]@{Name=$name;ready=[bool]$ready}
})
ConvertTo-Json -InputObject $data -Compress`;
  const { stdout } = await execFileAsync('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')],
    { windowsHide: true, timeout: 15000, maxBuffer: 1024 * 1024, encoding: 'utf8' });
  const adapters = JSON.parse(stdout.replace(/^\uFEFF/, '').trim());
  if (!Array.isArray(adapters)) throw new Error('Adapter query failed');
  return adapters;
}

function createApi(config) {
  return (method, resource, body) => new Promise((resolve, reject) => {
    const payload = body === undefined ? null : JSON.stringify(body);
    const request = http.request({ socketPath: `\\\\.\\pipe\\${config.pipeName}`, path: resource, method,
      headers: payload ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } : {} }, response => {
      let data = '';
      response.setEncoding('utf8');
      response.on('data', chunk => {
        data += chunk;
        if (data.length > 1024 * 1024) request.destroy(new Error('API response too large'));
      });
      response.on('error', reject);
      response.on('end', () => {
        if (response.statusCode < 200 || response.statusCode >= 300) return reject(new Error('API request failed'));
        try { resolve(data.trim() ? JSON.parse(data) : {}); } catch { reject(new Error('Invalid API response')); }
      });
    });
    const timer = setTimeout(() => request.destroy(new Error('API timeout')), 5000);
    request.on('close', () => clearTimeout(timer));
    request.on('error', reject);
    request.end(payload);
  });
}

function writeState(file, state) {
  if (!file) return;
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify({ ...state, desiredInterface: state.target,
    appliedInterface: state.appliedState, readyCount: state.recoveryCount,
    updatedAt: new Date().toISOString(), pid: process.pid }, null, 2) + '\n', 'utf8');
  fs.renameSync(temporary, file);
}

function createLogger(file) {
  return event => {
    const line = JSON.stringify({ time: new Date().toISOString(), ...event }) + '\n';
    if (file) {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      if (fs.existsSync(file) && fs.statSync(file).size + Buffer.byteLength(line) > 256 * 1024) {
        fs.copyFileSync(file, `${file}.last`);
        fs.writeFileSync(file, '', 'utf8');
      }
      fs.appendFileSync(file, line, 'utf8');
    } else {
      process.stdout.write(line);
    }
  };
}

async function acquireLock(config) {
  const key = crypto.createHash('sha256').update(config.pipeName).digest('hex').slice(0, 16);
  const address = `\\\\.\\pipe\\clash-dual-nic-fallback-${key}`;
  const server = net.createServer(socket => socket.end());
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(address, resolve); });
  return server;
}

async function main(args = process.argv.slice(2)) {
  const index = args.indexOf('--config');
  if (index === -1 || !args[index + 1] || args.some((value, i) => i !== index && i !== index + 1 && value !== '--once')) {
    throw new Error('Usage: node watch-fallback.cjs --config config.json [--once]');
  }
  const configPath = path.resolve(args[index + 1]);
  const config = normalizeConfig(JSON.parse(fs.readFileSync(configPath, 'utf8').replace(/^\uFEFF/, '')), path.dirname(configPath));
  const shouldStop = () => config.stopFile && fs.existsSync(config.stopFile);
  if (shouldStop()) return;
  let lock;
  try { lock = await acquireLock(config); } catch (error) {
    if (error.code === 'EADDRINUSE') return;
    throw new Error('Watcher lock unavailable');
  }
  const log = createLogger(config.logFile);
  const api = createApi(config);
  let state = createState();
  let lastEvent = '';
  let stopped = false;
  const stop = () => { stopped = true; };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
  try {
    do {
      if (stopped || shouldStop()) break;
      try {
        const adapters = await queryAdapters(config);
        if (stopped || shouldStop()) break;
        state = await tick(state, adapters, config, api);
      } catch {
        state = { ...state, recoveryCount: 0, changed: false, error: 'Adapter query failed' };
      }
      writeState(config.stateFile, state);
      const event = JSON.stringify({ status: state.status, target: state.target, appliedState: state.appliedState, error: state.error });
      if (event !== lastEvent || state.changed) { log(JSON.parse(event)); lastEvent = event; }
      if (args.includes('--once')) break;
      const end = Date.now() + config.intervalSeconds * 1000;
      while (!stopped && !shouldStop() && Date.now() < end) await new Promise(resolve => setTimeout(resolve, Math.min(500, end - Date.now())));
    } while (!stopped);
    log({ status: 'stopped' });
  } finally {
    process.removeListener('SIGINT', stop);
    process.removeListener('SIGTERM', stop);
    await new Promise(resolve => lock.close(resolve));
  }
}

module.exports = { normalizeConfig, createState, decideState, tick, queryAdapters, createApi, createLogger, main };
if (require.main === module) main().catch(() => { process.stderr.write('Fallback watcher stopped: configuration or runtime failure.\n'); process.exitCode = 1; });
