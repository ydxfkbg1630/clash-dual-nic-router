const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function transform(config, options = {}) {
  const source = fs.readFileSync(path.join(__dirname, '..', 'split-routing.js'), 'utf8');
  const context = vm.createContext({ input: config, overrides: options });
  vm.runInContext(source + '\nObject.assign(OPTIONS, overrides); output = main(input);', context);
  return JSON.parse(JSON.stringify(context.output));
}
function fixture() {
  return {
    ipv6: true,
    proxies: [
      { name: 'Example A', type: 'ss', server: 'proxy.example', port: 443, cipher: 'aes-128-gcm', password: 'example-only', 'interface-name': 'Old NIC' },
      { name: 'Example B', type: 'socks5', server: 'second.example', port: 1080 },
      { name: 'Custom direct', type: 'direct' },
      { name: 'Custom reject', type: 'reject' },
    ],
    'proxy-groups': [{ name: 'Existing', type: 'select', proxies: ['Example B', 'DIRECT'] }],
    rules: ['MATCH,DIRECT'],
  };
}

test('routes domestic traffic through Ethernet and proxy sockets through Wi-Fi without changing input', () => {
  const original = fixture();
  const before = structuredClone(original);
  const out = transform(original);
  assert.deepEqual(original, before);
  assert.equal(out['interface-name'], 'Ethernet');
  assert.equal(out.proxies[0]['interface-name'], 'Wi-Fi');
  assert.equal(out.proxies[1]['interface-name'], 'Wi-Fi');
  assert.equal(out.proxies[2]['interface-name'], 'Ethernet');
  assert.equal(out.proxies[0].password, 'example-only');
  assert.equal(out.ipv6, true);
  assert.deepEqual(out['proxy-groups'][0], before['proxy-groups'][0]);
  const group = out['proxy-groups'].at(-1);
  assert.deepEqual(group.proxies, ['Example A', 'Example B']);
  assert.equal(group.name, 'Overseas via Wi-Fi');
  assert.equal(out.rules.at(-1), 'MATCH,Overseas via Wi-Fi');
  for (const rule of ['GEOSITE,private,DIRECT', 'GEOSITE,cn,DIRECT', 'GEOIP,CN,DIRECT', 'IP-CIDR6,::1/128,DIRECT,no-resolve', 'IP-CIDR6,fc00::/7,DIRECT,no-resolve', 'IP-CIDR6,fe80::/10,DIRECT,no-resolve']) assert.ok(out.rules.includes(rule));
});

test('preferred local proxy comes first and missing or non-proxy preferences fail', () => {
  assert.deepEqual(transform(fixture(), { preferredProxy: 'Example B' })['proxy-groups'].at(-1).proxies, ['Example B', 'Example A']);
  for (const preferredProxy of ['Missing', 'Custom direct', 'Existing', 'DIRECT']) {
    assert.throws(() => transform(fixture(), { preferredProxy }), /preferredProxy/);
  }
});

test('preserves DNS and TUN options while enabling required routing settings', () => {
  const input = fixture();
  input.dns = { listen: '127.0.0.1:1053', nameserver: ['https://dns.example/dns-query'], 'fake-ip-filter': ['*.example'] };
  input.tun = { stack: 'mixed', mtu: 1400, 'auto-detect-interface': true };
  const out = transform(input);
  assert.equal(out.dns.enable, true);
  assert.equal(out.dns['enhanced-mode'], 'fake-ip');
  assert.deepEqual(out.dns.nameserver, input.dns.nameserver);
  assert.deepEqual(out.dns['fake-ip-filter'], ['*.example']);
  assert.equal(out.tun.enable, true);
  assert.equal(out.tun['auto-route'], true);
  assert.equal(out.tun['auto-detect-interface'], false);
  assert.equal(out.tun.mtu, 1400);
  assert.equal(out.tun.stack, 'mixed');
  const defaults = transform(fixture());
  assert.deepEqual(defaults.dns.nameserver, ['119.29.29.29', '223.5.5.5']);
  assert.equal(transform(fixture(), { tun: false }).tun.enable, false);
});

test('provider-only configuration adds use candidates and binds downloaded proxies', () => {
  const input = { 'proxy-providers': { Example: { type: 'http', url: 'https://subscription.example/proxies.yaml', interval: 3600, override: { udp: true } } } };
  const out = transform(input);
  assert.deepEqual(out['proxy-groups'].at(-1).use, ['Example']);
  assert.equal(out['proxy-providers'].Example.override['interface-name'], 'Wi-Fi');
  assert.equal(out['proxy-providers'].Example.override.udp, true);
  assert.match(out['proxy-providers'].Example['exclude-type'], /direct/);
  assert.match(out['proxy-groups'].at(-1)['exclude-type'], /Direct/);
});

test('rejects dynamic provider overrides and proxy chain directives with actionable errors', () => {
  const input = fixture();
  for (const target of ['DIRECT', 'Unknown', 'Example A']) {
    input.proxies[0]['dialer-proxy'] = target;
    assert.throws(() => transform(input), /dialer-proxy.*[Rr]emove/);
  }
  assert.throws(() => transform({ 'proxy-providers': { P: { type: 'http', 'override-expr': 'proxy => proxy' } } }), /override-expr/);
  assert.throws(() => transform({ 'proxy-providers': { P: { type: 'http', override: { 'override-expr': ['."interface-name" = "Other NIC"'] } } } }), /override-expr/);
  assert.throws(() => transform({ 'proxy-providers': { P: { type: 'http', override: { 'dialer-proxy': 'DIRECT' } } } }), /dialer-proxy/);
  assert.throws(() => transform({ 'proxy-providers': { P: { type: 'inline', payload: [{ name: 'Bad chain', type: 'ss', 'dialer-proxy': 'DIRECT' }] } } }), /dialer-proxy/);
});

test('supports inline providers while preserving provider filters and excluding direct candidates', () => {
  const input = { 'proxy-providers': { Example: { type: 'inline', 'exclude-type': 'http', payload: [
    { name: 'Example relay', type: 'socks5', server: 'relay.example', port: 1080 },
    { name: 'Example direct', type: 'direct' },
  ] } } };
  const out = transform(input, { domesticInterface: 'LAN Adapter', overseasInterface: 'Wireless Adapter' });
  assert.equal(out['interface-name'], 'LAN Adapter');
  assert.equal(out['proxy-providers'].Example.override['interface-name'], 'Wireless Adapter');
  assert.equal(out['proxy-providers'].Example.payload[0]['interface-name'], 'Wireless Adapter');
  assert.ok(out['proxy-providers'].Example['exclude-type'].split('|').includes('http'));
  assert.ok(out['proxy-providers'].Example['exclude-type'].split('|').includes('direct'));
  assert.deepEqual(transform(out, { domesticInterface: 'LAN Adapter', overseasInterface: 'Wireless Adapter' }), out);
  assert.throws(() => transform({ 'proxy-providers': { Empty: { type: 'inline', payload: [{ name: 'Only direct', type: 'direct' }] } } }), /real proxy/);
});

test('validates adapter settings and accepts only IP CIDR syntax for extra routes', () => {
  for (const options of [{ domesticInterface: '' }, { overseasInterface: 'Ethernet' }, { tun: 'true' }, { extraDirectCidrs: '10.0.0.0/8' }]) {
    assert.throws(() => transform(fixture(), options));
  }
  for (const cidr of ['1.2.3.4/33', '::/129', '1::2::3/64', '1:2:3/64', '010.0.0.1/8', '::gg/8', '10.0.0.0/8\nMATCH,REJECT']) {
    assert.throws(() => transform(fixture(), { extraDirectCidrs: [cidr] }), /CIDR/);
  }
  const input = fixture();
  delete input.ipv6;
  assert.equal(Object.hasOwn(transform(input), 'ipv6'), false);
});

test('keeps user groups with the default name and stays idempotent', () => {
  const input = fixture();
  input['proxy-groups'].push({ name: 'Overseas via Wi-Fi', type: 'select', proxies: ['DIRECT'] });
  const once = transform(input);
  const twice = transform(once);
  assert.deepEqual(twice, once);
  assert.deepEqual(once['proxy-groups'][1], input['proxy-groups'][1]);
  assert.equal(once['proxy-groups'].at(-1).name, 'Overseas via Wi-Fi (2)');
});

test('rejects empty configurations and validates additional direct ranges', () => {
  for (const input of [{}, { proxies: [{ name: 'Local', type: 'direct' }] }, null]) assert.throws(() => transform(input), /config|proxy|Proxy/);
  assert.throws(() => transform(fixture(), { extraDirectCidrs: ['MATCH,REJECT'] }), /CIDR/);
  assert.throws(() => transform(fixture(), { extraDirectCidrs: ['999.1.1.1/8'] }), /CIDR/);
  const out = transform(fixture(), { extraDirectCidrs: ['198.18.0.0/15', '2001:db8::/32'] });
  assert.ok(out.rules.includes('IP-CIDR,198.18.0.0/15,DIRECT,no-resolve'));
  assert.ok(out.rules.includes('IP-CIDR6,2001:db8::/32,DIRECT,no-resolve'));
});
