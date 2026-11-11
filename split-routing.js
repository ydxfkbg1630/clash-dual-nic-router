// Dual NIC Router - managed script
// Clash Verge Rev global extension script. See README.md for installation.
// BEGIN USER OPTIONS
const OPTIONS = {
  domesticInterface: 'Ethernet',
  overseasInterface: 'Wi-Fi',
  preferredProxy: '',
  tun: true,
  ruleMode: 'preserve',
  proxyIpVersion: 'ipv4',
  extraDirectCidrs: [],
  extraDirectDomains: [],
};
// END USER OPTIONS

function main(config) {
  const fail = (message) => { throw new Error('[dual-nic-router] ' + message); };
  const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
  const reservedTypes = new Set(['direct', 'reject', 'reject-drop', 'pass', 'compatible']);
  const reservedNames = new Set(['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE', 'GLOBAL']);
  const realProxy = (proxy) => isObject(proxy) && typeof proxy.name === 'string' && proxy.name.length > 0 &&
    typeof proxy.type === 'string' && proxy.type.length > 0 && !reservedTypes.has(proxy.type.toLowerCase()) &&
    !reservedNames.has(proxy.name.toUpperCase());
  const rejectChain = (value, location) => {
    if (isObject(value) && value['dialer-proxy']) {
      fail(location + ': dialer-proxy needs manual chain routing. Remove this option and use a standalone proxy.');
    }
  };
  if (!isObject(config)) fail('Provide a Clash configuration object containing a proxy or proxy-provider.');
  for (const key of ['domesticInterface', 'overseasInterface']) {
    if (typeof OPTIONS[key] !== 'string' || !OPTIONS[key].trim()) fail(key + ': provide an exact network adapter name.');
  }
  if (OPTIONS.domesticInterface === OPTIONS.overseasInterface) fail('Choose distinct domesticInterface and overseasInterface adapters.');
  if (typeof OPTIONS.tun !== 'boolean') fail('Set tun to true or false.');
  if (typeof OPTIONS.preferredProxy !== 'string') fail('Set preferredProxy to a local proxy name or an empty string.');
  if (!Array.isArray(OPTIONS.extraDirectCidrs)) fail('Set extraDirectCidrs to an array of CIDR strings.');
  if (!Array.isArray(OPTIONS.extraDirectDomains)) fail('Set extraDirectDomains to an array of domain names.');
  if (!['preserve', 'replace', 'strict'].includes(OPTIONS.ruleMode)) fail('Set ruleMode to preserve, replace, or strict.');
  if (!['dual', 'ipv4', 'ipv6', 'ipv4-prefer', 'ipv6-prefer'].includes(OPTIONS.proxyIpVersion)) fail('Set proxyIpVersion to dual, ipv4, ipv6, ipv4-prefer, or ipv6-prefer.');
  const strict = OPTIONS.ruleMode === 'strict';
  if (strict && (!OPTIONS.tun || OPTIONS.proxyIpVersion !== 'ipv4')) fail('strict mode requires tun: true and proxyIpVersion: ipv4.');
  const udpSwitchTypes = new Set(['ss', 'trojan', 'vmess', 'vless', 'socks5']);
  const bindRemote = (proxy) => {
    proxy['interface-name'] = OPTIONS.overseasInterface;
    proxy['ip-version'] = OPTIONS.proxyIpVersion;
    // This enables client UDP forwarding; the remote server must also support it.
    if (strict && udpSwitchTypes.has(proxy.type.toLowerCase())) proxy.udp = true;
  };

  // Clash hands the extension a JSON-compatible configuration object.
  const out = JSON.parse(JSON.stringify(config));
  const proxies = out.proxies === undefined ? [] : out.proxies;
  const groups = out['proxy-groups'] === undefined ? [] : out['proxy-groups'];
  const providers = out['proxy-providers'] === undefined ? {} : out['proxy-providers'];
  if (!Array.isArray(proxies) || !Array.isArray(groups) || !isObject(providers)) fail('Use arrays for proxies/proxy-groups and a mapping for proxy-providers.');
  const candidates = [];
  for (const proxy of proxies) {
    if (!isObject(proxy)) fail('Each proxy must be a configuration object.');
    rejectChain(proxy, 'Proxy ' + proxy.name);
    if (String(proxy.type).toLowerCase() === 'direct') proxy['interface-name'] = OPTIONS.domesticInterface;
    else if (realProxy(proxy)) {
      bindRemote(proxy);
      if (!candidates.includes(proxy.name)) candidates.push(proxy.name);
    }
  }
  const providerNames = Object.keys(providers);
  for (const name of providerNames) {
    const provider = providers[name];
    if (!isObject(provider)) fail('Provider ' + name + ': provide a configuration object.');
    const override = provider.override === undefined ? {} : provider.override;
    if (!isObject(override)) fail('Provider ' + name + ': override must be a mapping.');
    if (provider['override-expr'] !== undefined || override['override-expr'] !== undefined) {
      fail('Provider ' + name + ': remove override-expr and express required changes as ordinary override fields; expressions can replace interface-name.');
    }
    rejectChain(provider, 'Provider ' + name);
    rejectChain(override, 'Provider ' + name + ' override');
    if (provider.payload !== undefined) {
      if (!Array.isArray(provider.payload)) fail('Provider ' + name + ': payload must be an array.');
      for (const proxy of provider.payload) {
        rejectChain(proxy, 'Provider ' + name + ' payload');
        if (realProxy(proxy)) {
          bindRemote(proxy);
        }
        else if (isObject(proxy) && String(proxy.type).toLowerCase() === 'direct') proxy['interface-name'] = OPTIONS.domesticInterface;
      }
      if (provider.type === 'inline' && !provider.payload.some(realProxy)) fail('Provider ' + name + ': add a real proxy to the inline payload.');
    } else if (provider.type === 'inline') fail('Provider ' + name + ': add a real proxy payload.');
    provider.override = Object.assign({}, override, { 'interface-name': OPTIONS.overseasInterface, 'ip-version': OPTIONS.proxyIpVersion });
    if (strict) provider.override.udp = true;
    provider['exclude-type'] = [...new Set(String(provider['exclude-type'] || '').split('|').filter(Boolean).concat([...reservedTypes]))].join('|');
  }
  if (!candidates.length && !providerNames.length) fail('Add at least one real proxy or proxy-provider to the configuration.');
  if (OPTIONS.preferredProxy) {
    const index = candidates.indexOf(OPTIONS.preferredProxy);
    if (index < 0) fail('preferredProxy: choose a real proxy from the top-level proxies list; use an empty string for provider-only subscriptions.');
    candidates.splice(index, 1);
    candidates.unshift(OPTIONS.preferredProxy);
  }

  // A metadata key identifies our own group across repeated transformations.
  const marker = 'x-dual-nic-router-group';
  const previous = out[marker];
  const existing = groups.filter((group) => !(typeof previous === 'string' && group.name === previous));
  const names = new Set(proxies.concat(existing).map((item) => item.name));
  let groupName = 'Overseas via Wi-Fi';
  for (let suffix = 2; names.has(groupName); suffix++) groupName = 'Overseas via Wi-Fi (' + suffix + ')';
  const group = { name: groupName, type: 'select', 'exclude-type': 'Direct|Reject|RejectDrop|Pass|Compatible' };
  if (candidates.length) group.proxies = candidates;
  if (providerNames.length) group.use = providerNames;
  out['proxy-groups'] = existing.concat([group]);
  out[marker] = groupName;
  out['interface-name'] = OPTIONS.domesticInterface;
  out.mode = 'rule';

  const ruleMarker = 'x-dual-nic-router-rules';
  const previousRules = out[ruleMarker];
  let originalRules = out.rules === undefined ? [] : out.rules;
  if (!Array.isArray(originalRules) || !originalRules.every((rule) => typeof rule === 'string')) fail('rules must be an array of strings.');
  if (previousRules !== undefined) {
    if (!isObject(previousRules) || !Array.isArray(previousRules.prefix) || !Array.isArray(previousRules.suffix)) {
      fail('Restore x-dual-nic-router-rules metadata from the previous generated configuration.');
    }
    const { prefix, suffix } = previousRules;
    if (originalRules.length < prefix.length + suffix.length ||
      !prefix.every((rule, index) => originalRules[index] === rule) ||
      !suffix.every((rule, index) => originalRules[originalRules.length - suffix.length + index] === rule)) {
      fail('Generated rule boundaries changed. Restore the generated prefix/suffix before applying the script again.');
    }
    originalRules = originalRules.slice(prefix.length, originalRules.length - suffix.length);
  }
  const rules = [
    'IP-CIDR,0.0.0.0/8,DIRECT,no-resolve',
    'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
    'IP-CIDR,100.64.0.0/10,DIRECT,no-resolve',
    'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve',
    'IP-CIDR,169.254.0.0/16,DIRECT,no-resolve',
    'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve',
    'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',
    'IP-CIDR6,::1/128,DIRECT,no-resolve',
    'IP-CIDR6,fc00::/7,DIRECT,no-resolve',
    'IP-CIDR6,fe80::/10,DIRECT,no-resolve',
  ];
  const directCidrs = [...new Set(OPTIONS.extraDirectCidrs)];
  for (const cidr of directCidrs) {
    if (typeof cidr !== 'string') fail('Use IPv4 or IPv6 CIDR strings in extraDirectCidrs.');
    const parts = cidr.split('/');
    const address = parts[0];
    const prefix = parts[1];
    let valid = parts.length === 2 && /^\d{1,3}$/.test(prefix);
    const ipv6 = address.includes(':');
    if (ipv6) {
      const halves = address.split('::');
      const words = halves.flatMap((half) => half ? half.split(':') : []);
      valid = valid && Number(prefix) <= 128 && halves.length <= 2 && words.every((word) => /^[\da-fA-F]{1,4}$/.test(word)) &&
        (halves.length === 2 ? words.length < 8 : words.length === 8);
    } else {
      const octets = address.split('.');
      valid = valid && Number(prefix) <= 32 && octets.length === 4 && octets.every((octet) => /^(0|[1-9]\d{0,2})$/.test(octet) && Number(octet) <= 255);
    }
    if (!valid) fail('Invalid CIDR in extraDirectCidrs: ' + cidr);
    rules.push((ipv6 ? 'IP-CIDR6,' : 'IP-CIDR,') + cidr + ',DIRECT,no-resolve');
  }
  const directDomains = [];
  for (const domain of OPTIONS.extraDirectDomains) {
    if (typeof domain !== 'string') fail('Use domain names in extraDirectDomains.');
    const normalized = domain.toLowerCase().replace(/\.$/, '');
    const valid = normalized.length > 0 && normalized.length <= 253 &&
      normalized.split('.').every((label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)) &&
      !/^\d+(\.\d+){3}$/.test(normalized);
    if (!valid) fail('Invalid domain in extraDirectDomains: ' + domain + '. Use an ASCII hostname; put IP ranges in extraDirectCidrs.');
    if (!directDomains.includes(normalized)) directDomains.push(normalized);
  }
  const prefix = [...new Set(directDomains.map((domain) => 'DOMAIN-SUFFIX,' + domain + ',DIRECT').concat(rules))];
  const preserved = OPTIONS.ruleMode === 'preserve' ? originalRules : [];
  const overseasDomains = ['microsoft.com', 'microsoftonline.com', 'live.com', 'bing.com', 'apple.com', 'icloud.com'];
  const suffix = strict ? ['GEOSITE,private,DIRECT']
    .concat(overseasDomains.map((domain) => 'DOMAIN-SUFFIX,' + domain + ',' + groupName),
      ['GEOSITE,geolocation-!cn,' + groupName, 'GEOSITE,cn,DIRECT', 'GEOIP,CN,DIRECT', 'MATCH,' + groupName]) :
    preserved.some((rule) => /^\s*(MATCH|FINAL)\s*,/i.test(rule)) ? [] :
      ['GEOSITE,private,DIRECT', 'GEOSITE,cn,DIRECT', 'GEOIP,CN,DIRECT', 'MATCH,' + groupName];
  out.rules = prefix.concat(preserved, suffix);
  if (out.dns !== undefined && !isObject(out.dns)) fail('dns must be a mapping.');
  if (out.tun !== undefined && !isObject(out.tun)) fail('tun must be a mapping.');
  out.dns = Object.assign({ nameserver: ['119.29.29.29', '223.5.5.5'] }, out.dns || {}, { enable: true, 'enhanced-mode': 'fake-ip' });
  out.tun = Object.assign({}, out.tun || {}, { enable: OPTIONS.tun, 'auto-route': true, 'auto-detect-interface': false });
  const mergeGenerated = (object, key, added, previousAdded, prepend = false) => {
    const current = object[key] === undefined ? [] : object[key];
    if (!Array.isArray(current) || !current.every((item) => typeof item === 'string')) fail(key + ' must be an array of strings.');
    if (previousAdded !== undefined && (!Array.isArray(previousAdded) || !previousAdded.every((item) => typeof item === 'string'))) fail('Restore generated ' + key + ' metadata.');
    const base = current.filter((item) => !(previousAdded || []).includes(item));
    const generated = added.filter((item) => !base.includes(item));
    if (object[key] !== undefined || added.length) object[key] = [...new Set(prepend ? added.concat(base) : base.concat(generated))];
    return generated;
  };
  const filterMode = out.dns['fake-ip-filter-mode'] || 'blacklist';
  if (directDomains.length && !['blacklist', 'rule'].includes(filterMode)) {
    fail('extraDirectDomains requires dns.fake-ip-filter-mode blacklist or rule. Convert the existing whitelist explicitly before adding portal domains.');
  }
  const filters = directDomains.map((domain) => filterMode === 'rule' ? 'DOMAIN-SUFFIX,' + domain + ',real-ip' : '+.' + domain);
  const dnsFilters = mergeGenerated(out.dns, 'fake-ip-filter', filters, previousRules && previousRules.dnsFilters, filterMode === 'rule');
  const tunExclusions = mergeGenerated(out.tun, 'route-exclude-address', directCidrs, previousRules && previousRules.tunExclusions);
  out[ruleMarker] = { prefix, suffix, dnsFilters, tunExclusions };
  const oldPolicies = previousRules && previousRules.dnsPolicies;
  if (oldPolicies !== undefined && !isObject(oldPolicies)) fail('Restore generated nameserver-policy metadata.');
  if (out.dns['nameserver-policy'] !== undefined && !isObject(out.dns['nameserver-policy'])) fail('dns.nameserver-policy must be a mapping.');
  const policies = out.dns['nameserver-policy'] || {};
  for (const key of Object.keys(oldPolicies || {})) {
    if (JSON.stringify(policies[key]) === JSON.stringify(oldPolicies[key])) delete policies[key];
  }
  if (strict) {
    out.ipv6 = false;
    out['find-process-mode'] = 'always';
    out.dns.ipv6 = false;
    out.dns['respect-rules'] = true;
    out.dns['prefer-h3'] = false;
    const domesticDns = ['119.29.29.29', '223.5.5.5'];
    // Independent IP-based defaults break the DNS -> proxy hostname -> DNS cycle.
    // Explicit upstream choices remain owned by the subscription/user.
    for (const key of ['default-nameserver', 'proxy-server-nameserver', 'direct-nameserver']) {
      if (out.dns[key] === undefined || (Array.isArray(out.dns[key]) && out.dns[key].length === 0)) out.dns[key] = domesticDns.slice();
      if (!Array.isArray(out.dns[key]) || !out.dns[key].every((item) => typeof item === 'string')) fail('dns.' + key + ' must be an array of nameservers.');
    }
    out.dns['direct-nameserver-follow-policy'] = true;
    const generatedPolicies = {};
    for (const key of ['geosite:private', 'geosite:cn'].concat(directDomains.map((domain) => '+.' + domain))) {
      if (!Object.prototype.hasOwnProperty.call(policies, key)) {
        policies[key] = domesticDns.slice();
        generatedPolicies[key] = domesticDns.slice();
      }
    }
    out.dns['nameserver-policy'] = policies;
    out[ruleMarker].dnsPolicies = generatedPolicies;
    out.tun['strict-route'] = true;
    mergeGenerated(out.tun, 'dns-hijack', ['any:53', 'tcp://any:53']);
    if (out.sniffer !== undefined && !isObject(out.sniffer)) fail('sniffer must be a mapping.');
    out.sniffer = Object.assign({}, out.sniffer || {}, { enable: true, 'parse-pure-ip': true, 'override-destination': false });
    if (out.sniffer.sniff !== undefined && !isObject(out.sniffer.sniff)) fail('sniffer.sniff must be a mapping.');
    out.sniffer.sniff = out.sniffer.sniff || {};
    for (const [protocol, ports] of [['HTTP', [80, '8080-8880']], ['TLS', [443, 8443]], ['QUIC', [443, 8443]]]) {
      const current = out.sniffer.sniff[protocol];
      if (current !== undefined && !isObject(current)) fail('sniffer.sniff.' + protocol + ' must be a mapping.');
      const existingPorts = (current && current.ports) || [];
      if (!Array.isArray(existingPorts)) fail('sniffer.sniff.' + protocol + '.ports must be an array.');
      out.sniffer.sniff[protocol] = Object.assign({}, current || {}, { ports: [...new Set(existingPorts.concat(ports))], 'override-destination': false });
    }
  }
  return out;
}
