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
  assert.equal(out.rules.at(-1), 'MATCH,DIRECT');
  for (const rule of ['IP-CIDR6,::1/128,DIRECT,no-resolve', 'IP-CIDR6,fc00::/7,DIRECT,no-resolve', 'IP-CIDR6,fe80::/10,DIRECT,no-resolve']) assert.ok(out.rules.includes(rule));
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

test('preserve mode retains every original rule, its order, and its final policy', () => {
  const input = fixture();
  input.rules = ['DOMAIN,ads.example,REJECT', 'PROCESS-NAME,game.exe,Existing', 'DOMAIN,special.example,Example B', 'MATCH,Existing', 'DOMAIN,after.example,DIRECT'];
  const out = transform(input);
  assert.deepEqual(out.rules.slice(-input.rules.length), input.rules);
  assert.equal(out.rules.filter((rule) => rule.startsWith('MATCH,')).length, 1);
  assert.deepEqual(transform(out), out);
  assert.throws(() => transform(input, { ruleMode: 'invalid' }), /ruleMode/);
});

test('appends domestic and overseas defaults only when original rules have no terminal rule', () => {
  const input = fixture();
  input.rules = ['DOMAIN,ads.example,REJECT'];
  const out = transform(input);
  assert.deepEqual(out.rules.slice(-5), input.rules.concat(['GEOSITE,private,DIRECT', 'GEOSITE,cn,DIRECT', 'GEOIP,CN,DIRECT', 'MATCH,Overseas via Wi-Fi']));
  assert.deepEqual(transform(out), out);
  input.rules = ['FINAL,Existing'];
  assert.equal(transform(input).rules.at(-1), 'FINAL,Existing');
});

test('replace mode explicitly selects full domestic and overseas routing', () => {
  const input = fixture();
  const out = transform(input, { ruleMode: 'replace' });
  assert.equal(out.rules.includes('MATCH,DIRECT'), false);
  assert.deepEqual(out.rules.slice(-4), ['GEOSITE,private,DIRECT', 'GEOSITE,cn,DIRECT', 'GEOIP,CN,DIRECT', 'MATCH,Overseas via Wi-Fi']);
  assert.deepEqual(transform(out, { ruleMode: 'replace' }), out);
});

test('public portal and DNS ranges bypass TUN while portal domains receive real IPs', () => {
  const input = fixture();
  input.dns = { 'fake-ip-filter': ['+.already.example'], 'fake-ip-filter-mode': 'blacklist' };
  input.tun = { 'route-exclude-address': ['203.0.113.8/32'] };
  const options = { extraDirectCidrs: ['198.51.100.2/32', '2001:db8::/32', '198.51.100.2/32'], extraDirectDomains: ['Portal.Example.', 'portal.example', 'already.example'] };
  const out = transform(input, options);
  assert.deepEqual(out.dns['fake-ip-filter'], ['+.already.example', '+.portal.example']);
  assert.deepEqual(out.tun['route-exclude-address'], ['203.0.113.8/32', '198.51.100.2/32', '2001:db8::/32']);
  assert.deepEqual(out.rules.slice(0, 2), ['DOMAIN-SUFFIX,portal.example,DIRECT', 'DOMAIN-SUFFIX,already.example,DIRECT']);
  assert.ok(out.rules.includes('IP-CIDR,198.51.100.2/32,DIRECT,no-resolve'));
  assert.deepEqual(transform(out, options), out);
  const cleared = transform(out);
  assert.deepEqual(cleared.dns['fake-ip-filter'], input.dns['fake-ip-filter']);
  assert.deepEqual(cleared.tun['route-exclude-address'], input.tun['route-exclude-address']);
  assert.equal(cleared.rules.some((rule) => rule.includes('portal.example')), false);
});

test('supports rule-based fake-IP filters and explains whitelist conversion', () => {
  const input = fixture();
  input.dns = { 'fake-ip-filter-mode': 'rule', 'fake-ip-filter': ['MATCH,fake-ip', 'DOMAIN-SUFFIX,portal.example,real-ip'] };
  const options = { extraDirectDomains: ['portal.example', 'login.example'] };
  const out = transform(input, options);
  assert.deepEqual(out.dns['fake-ip-filter'], ['DOMAIN-SUFFIX,portal.example,real-ip', 'DOMAIN-SUFFIX,login.example,real-ip', 'MATCH,fake-ip']);
  assert.deepEqual(transform(out, options), out);
  input.dns = { 'fake-ip-filter-mode': 'whitelist', 'fake-ip-filter': ['+.example'] };
  assert.deepEqual(transform(input).dns['fake-ip-filter'], ['+.example']);
  assert.throws(() => transform(input, options), /whitelist.*explicitly/);
});

test('validates domain names and preserves input on every validation failure', () => {
  const input = fixture();
  const before = structuredClone(input);
  for (const domain of ['portal.example\nMATCH,REJECT', 'portal.example,DIRECT', '*.example', 'https://portal.example', '-invalid.example', 'a'.repeat(64) + '.example', '192.0.2.1', ' portal.example', '', null]) {
    assert.throws(() => transform(input, { extraDirectDomains: [domain] }), /domain|extraDirectDomains/);
  }
  assert.throws(() => transform(input, { extraDirectDomains: 'portal.example' }), /extraDirectDomains/);
  assert.deepEqual(input, before);
});

test('defaults remote proxy connections to IPv4 while keeping direct and global IPv6 settings', () => {
  const input = fixture();
  input.proxies[2]['ip-version'] = 'ipv6-prefer';
  input.dns = { ipv6: true };
  input['proxy-providers'] = { Inline: { type: 'inline', override: { udp: true, 'ip-version': 'ipv6' }, payload: [
    { name: 'Remote', type: 'socks5', server: 'proxy.example', port: 1080 },
    { name: 'Local', type: 'direct', 'ip-version': 'ipv6' },
  ] } };
  for (const proxyIpVersion of ['ipv4', 'dual', 'ipv6', 'ipv4-prefer', 'ipv6-prefer']) {
    const out = transform(input, { proxyIpVersion });
    assert.equal(out.proxies[0]['ip-version'], proxyIpVersion);
    assert.equal(out.proxies[1]['ip-version'], proxyIpVersion);
    assert.equal(out['proxy-providers'].Inline.override['ip-version'], proxyIpVersion);
    assert.equal(out['proxy-providers'].Inline.override.udp, true);
    assert.equal(out['proxy-providers'].Inline.payload[0]['ip-version'], proxyIpVersion);
    assert.equal(out['proxy-providers'].Inline.payload[1]['ip-version'], 'ipv6');
    assert.equal(out.proxies[2]['ip-version'], 'ipv6-prefer');
    assert.equal(out.ipv6, true);
    assert.equal(out.dns.ipv6, true);
  }
  assert.equal(transform(input).proxies[0]['ip-version'], 'ipv4');
  assert.throws(() => transform(input, { proxyIpVersion: 'v4' }), /proxyIpVersion/);
});

test('updates generated exclusions without deleting original duplicate or similar rules', () => {
  const input = fixture();
  input.rules.unshift('DOMAIN-SUFFIX,portal.example,DIRECT');
  const once = transform(input, { extraDirectDomains: ['portal.example'] });
  const twice = transform(once, { extraDirectDomains: ['login.example'] });
  assert.deepEqual(twice.rules.slice(-input.rules.length), input.rules);
  assert.equal(twice.rules[0], 'DOMAIN-SUFFIX,login.example,DIRECT');
  assert.equal(twice.rules.filter((rule) => rule === 'DOMAIN-SUFFIX,portal.example,DIRECT').length, 1);
  const edited = structuredClone(once);
  edited.rules[0] = 'DOMAIN-SUFFIX,portal.example,REJECT';
  assert.throws(() => transform(edited), /boundaries changed/);
});

test('strict mode prioritizes overseas domains and replaces subscription direct exceptions', () => {
  const input = fixture();
  input.rules = ['DOMAIN-SUFFIX,microsoft.com,DIRECT', 'MATCH,DIRECT'];
  const before = structuredClone(input);
  const options = { ruleMode: 'strict', extraDirectDomains: ['portal.example'] };
  const out = transform(input, options);
  assert.deepEqual(input, before);
  assert.equal(out.rules[0], 'DOMAIN-SUFFIX,portal.example,DIRECT');
  assert.equal(out.rules.includes('MATCH,DIRECT'), false);
  const overseas = out.rules.indexOf('GEOSITE,geolocation-!cn,Overseas via Wi-Fi');
  assert.ok(overseas > out.rules.indexOf('GEOSITE,private,DIRECT'));
  assert.ok(overseas < out.rules.indexOf('GEOSITE,cn,DIRECT'));
  for (const domain of ['microsoft.com', 'microsoftonline.com', 'live.com', 'bing.com', 'apple.com', 'icloud.com']) {
    const position = out.rules.indexOf('DOMAIN-SUFFIX,' + domain + ',Overseas via Wi-Fi');
    assert.ok(position > -1 && position < overseas);
  }
  assert.deepEqual(out.rules.slice(-3), ['GEOSITE,cn,DIRECT', 'GEOIP,CN,DIRECT', 'MATCH,Overseas via Wi-Fi']);
  assert.deepEqual(out['proxy-groups'].at(-1).proxies, ['Example A', 'Example B']);
  assert.deepEqual(transform(out, options), out);
});

test('strict mode requires IPv4 proxy transport and TUN, enables route and DNS interception', () => {
  for (const options of [{ tun: false }, { proxyIpVersion: 'dual' }, { proxyIpVersion: 'ipv6' }]) {
    assert.throws(() => transform(fixture(), { ruleMode: 'strict', ...options }), /strict.*tun.*ipv4/i);
  }
  const input = fixture();
  input.tun = { stack: 'mixed', 'strict-route': false, 'dns-hijack': ['udp://192.0.2.53:53'] };
  const out = transform(input, { ruleMode: 'strict' });
  assert.equal(out.ipv6, false);
  assert.equal(out.dns.ipv6, false);
  assert.equal(out['find-process-mode'], 'always');
  assert.equal(out.tun.enable, true);
  assert.equal(out.tun['strict-route'], true);
  assert.equal(out.tun.stack, 'mixed');
  assert.deepEqual(out.tun['dns-hijack'], ['udp://192.0.2.53:53', 'any:53', 'tcp://any:53']);
  assert.equal(out.sniffer.enable, true);
  assert.equal(out.sniffer['parse-pure-ip'], true);
  for (const protocol of ['HTTP', 'TLS', 'QUIC']) assert.equal(out.sniffer.sniff[protocol]['override-destination'], false);
});

test('strict DNS keeps custom upstreams, supplies independent bootstrap, and merges portal policies', () => {
  const input = fixture();
  input.dns = { nameserver: ['https://dns.example/dns-query'], fallback: ['tls://fallback.example'],
    'prefer-h3': true, 'nameserver-policy': { '+.custom.example': '192.0.2.53', '+.portal.example': ['192.0.2.54'] } };
  input.sniffer = { 'skip-domain': ['+.sensitive.example'], sniff: { HTTP: { ports: [8080], 'override-destination': true } } };
  const before = structuredClone(input);
  const options = { ruleMode: 'strict', extraDirectDomains: ['portal.example', 'login.example'] };
  const out = transform(input, options);
  assert.deepEqual(input, before);
  assert.deepEqual(out.dns.nameserver, input.dns.nameserver);
  assert.deepEqual(out.dns.fallback, input.dns.fallback);
  assert.equal(out.dns['respect-rules'], true);
  assert.equal(out.dns['prefer-h3'], false);
  assert.deepEqual(out.dns['default-nameserver'], ['119.29.29.29', '223.5.5.5']);
  assert.deepEqual(out.dns['proxy-server-nameserver'], ['119.29.29.29', '223.5.5.5']);
  assert.deepEqual(out.dns['direct-nameserver'], ['119.29.29.29', '223.5.5.5']);
  assert.equal(out.dns['direct-nameserver-follow-policy'], true);
  assert.deepEqual(out.dns['nameserver-policy']['+.portal.example'], ['192.0.2.54']);
  assert.deepEqual(out.dns['nameserver-policy']['+.login.example'], ['119.29.29.29', '223.5.5.5']);
  assert.equal(out.dns['nameserver-policy']['+.custom.example'], '192.0.2.53');
  assert.deepEqual(out.sniffer['skip-domain'], input.sniffer['skip-domain']);
  assert.ok(out.sniffer.sniff.HTTP.ports.includes(8080));
  assert.deepEqual(transform(out, options), out);
  const cleared = transform(out, { ruleMode: 'strict' });
  assert.equal(Object.hasOwn(cleared.dns['nameserver-policy'], '+.login.example'), false);
  assert.deepEqual(cleared.dns['nameserver-policy']['+.portal.example'], ['192.0.2.54']);
});

test('strict DNS preserves explicitly configured bootstrap and direct upstreams', () => {
  const input = fixture();
  input.dns = { 'default-nameserver': ['192.0.2.51'], 'proxy-server-nameserver': ['192.0.2.52'], 'direct-nameserver': ['192.0.2.53'] };
  const out = transform(input, { ruleMode: 'strict' });
  for (const key of Object.keys(input.dns)) assert.deepEqual(out.dns[key], input.dns[key]);
});

test('strict mode enables UDP on supported node types and provider overrides', () => {
  const input = fixture();
  input.proxies = ['ss', 'trojan', 'vmess', 'vless', 'socks5', 'http'].map((type) => ({ name: type, type, udp: false }));
  input['proxy-providers'] = { Inline: { type: 'inline', payload: [{ name: 'Relay', type: 'ss', udp: false }] }, Remote: { type: 'http', url: 'https://subscription.example/proxies.yaml' } };
  const out = transform(input, { ruleMode: 'strict' });
  for (const proxy of out.proxies.slice(0, 5)) assert.equal(proxy.udp, true);
  assert.equal(out.proxies.at(-1).udp, false);
  assert.equal(out['proxy-providers'].Inline.payload[0].udp, true);
  for (const provider of Object.values(out['proxy-providers'])) assert.equal(provider.override.udp, true);
  assert.deepEqual(transform(out, { ruleMode: 'strict' }), out);
});
