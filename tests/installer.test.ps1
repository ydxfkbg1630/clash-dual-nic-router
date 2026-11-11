$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$install = Join-Path $repo 'scripts\Install-Routing.ps1'
$restore = Join-Path $repo 'scripts\Restore-Routing.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('dual-nic-test-' + [guid]::NewGuid().ToString('N'))
$config = Join-Path $root '配置目录'
$state = Join-Path $root 'state'
New-Item -ItemType Directory -Path (Join-Path $config 'profiles') -Force | Out-Null
# Mock network discovery; file operations use real temporary files.
function Get-NetAdapter {
    [pscustomobject]@{Name='Test Ethernet';Status='Up'}
    [pscustomobject]@{Name='Test Wi-Fi';Status='Up'}
}
function Get-DnsClientServerAddress {
    param([string]$InterfaceAlias)
    if ($InterfaceAlias -ne 'Test Ethernet') { throw 'DNS discovery used the wrong adapter.' }
    [pscustomobject]@{ServerAddresses=@('192.0.2.53', '2001:db8::53')}
}
function Get-NetIPConfiguration {
    param([string]$InterfaceAlias)
    if ($InterfaceAlias -ne 'Test Ethernet') { throw 'Gateway discovery used the wrong adapter.' }
    [pscustomobject]@{
        IPv4DefaultGateway=[pscustomobject]@{NextHop='192.0.2.1'}
        IPv6DefaultGateway=[pscustomobject]@{NextHop='fe80::1%7'}
    }
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Read-GeneratedOptions($path) {
    $match = [regex]::Match([IO.File]::ReadAllText($path), '(?s)const OPTIONS = (.*?);\s*// END USER OPTIONS')
    Assert $match.Success 'Generated options block is missing.'
    return ($match.Groups[1].Value | ConvertFrom-Json)
}
$target = Join-Path $config 'profiles\Script.js'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$original = "// user extension`nfunction main(config) { config.example = true; return config; }"
[IO.File]::WriteAllText($target,$original,$utf8)
$hash = (Get-FileHash $target).Hash
& $install -DomesticInterface 'Test Ethernet' -OverseasInterface 'Test Wi-Fi' -ConfigDirectory $config -StateDirectory $state | Out-Null
Assert ((Get-FileHash $target).Hash -eq $hash) 'Generate-only changed the active file.'
$generated = Get-ChildItem -LiteralPath $state -Filter Script.js -Recurse | Select-Object -First 1
$defaults = Read-GeneratedOptions $generated.FullName
Assert ($defaults.ruleMode -eq 'preserve') 'Default rule preservation failed.'
Assert ($defaults.proxyIpVersion -eq 'ipv4') 'Default proxy IPv4 policy failed.'
Assert ($defaults.tun -eq $true) 'Default TUN setting changed.'
foreach ($cidr in @('192.0.2.53/32','2001:db8::53/128','192.0.2.1/32','fe80::1/128')) {
    Assert ($defaults.extraDirectCidrs -contains $cidr) "Missing discovered direct address: $cidr"
}
Assert ($defaults.extraDirectDomains.Count -eq 0) 'Portal domains must be supplied explicitly.'
$offlineState = Join-Path $root 'offline'
& $install -DomesticInterface 'Test Ethernet' -OverseasInterface 'Test Wi-Fi' -StateDirectory $offlineState -SkipNetworkDiscovery -RuleMode replace -ProxyIpVersion dual -ExtraDirectCidrs '192.0.2.80/32' -ExtraDirectDomains 'portal.example.test' | Out-Null
$offlineScript = Get-ChildItem -LiteralPath $offlineState -Filter Script.js -Recurse | Select-Object -First 1
$offlineOptions = Read-GeneratedOptions $offlineScript.FullName
Assert ($offlineOptions.ruleMode -eq 'replace' -and $offlineOptions.proxyIpVersion -eq 'dual') 'Explicit policy overrides failed.'
Assert ($offlineOptions.extraDirectCidrs.Count -eq 1 -and $offlineOptions.extraDirectCidrs[0] -eq '192.0.2.80/32') 'Skipped discovery changed explicit CIDRs.'
Assert ($offlineOptions.extraDirectDomains[0] -eq 'portal.example.test') 'Explicit portal domain was lost.'
$blocked = $false
try { & $install -DomesticInterface 'Test Ethernet' -OverseasInterface 'Test Wi-Fi' -ConfigDirectory $config -StateDirectory $state -Install | Out-Null } catch { $blocked=$true }
Assert $blocked 'Custom-script guard failed.'
& $install -DomesticInterface 'Test Ethernet' -OverseasInterface 'Test Wi-Fi' -PreferredProxy 'Node $1 "quoted"' -ExtraDirectDomains 'portal.example.test' -ExtraDirectCidrs @('192.0.2.80/32','192.0.2.53/32') -ConfigDirectory $config -StateDirectory $state -Install -ReplaceExisting | Out-Null
$installedOptions = Read-GeneratedOptions $target
Assert ($installedOptions.preferredProxy -eq 'Node $1 "quoted"') 'Proxy name escaping failed.'
Assert ($installedOptions.extraDirectCidrs -contains '192.0.2.80/32') 'Explicit portal CIDR was lost.'
Assert (@($installedOptions.extraDirectCidrs | Where-Object { $_ -eq '192.0.2.53/32' }).Count -eq 1) 'Discovered DNS address was duplicated.'
Assert ($installedOptions.extraDirectDomains[0] -eq 'portal.example.test') 'Installed portal domain was lost.'
$manifest = Get-ChildItem -LiteralPath $state -Filter manifest.json -Recurse | Select-Object -First 1
Assert ($null -ne $manifest) 'Missing backup manifest.'
$backup = $manifest.DirectoryName
Assert ([IO.File]::ReadAllText((Join-Path $backup 'original.js')) -eq $original) 'Original backup differs.'
& node --check $target
Assert ($LASTEXITCODE -eq 0) 'Generated script syntax failed.'
@'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), context);
const output = context.main({
  proxies: [{ name: 'Node $1 "quoted"', type: 'ss', server: 'proxy.example.test', port: 443 }],
  rules: ['DOMAIN,ads.example.test,REJECT', 'MATCH,DIRECT'],
  tun: { 'route-exclude-address': ['198.51.100.1/32'] },
});
for (const cidr of ['192.0.2.53/32', '2001:db8::53/128', '192.0.2.1/32', 'fe80::1/128', '192.0.2.80/32', '198.51.100.1/32']) {
  assert(output.tun['route-exclude-address'].includes(cidr), 'Missing TUN exclusion: ' + cidr);
}
assert(output.rules.includes('DOMAIN-SUFFIX,portal.example.test,DIRECT'));
assert(output.rules.includes('DOMAIN,ads.example.test,REJECT'));
assert(output.dns['fake-ip-filter'].includes('+.portal.example.test'));
assert.equal(output.proxies[0]['interface-name'], 'Test Wi-Fi');
assert.equal(output.proxies[0]['ip-version'], 'ipv4');
'@ | & node - $target
Assert ($LASTEXITCODE -eq 0) 'Generated script routing integration failed.'
Add-Content -LiteralPath $target -Value '// subsequent edit'
$editedHash = (Get-FileHash $target).Hash
$blocked=$false
try { & $restore -BackupDirectory $backup | Out-Null } catch { $blocked=$true }
Assert $blocked 'Changed-script restore guard failed.'
Assert ((Get-FileHash $target).Hash -eq $editedHash) 'Guard changed the edited script.'
& $restore -BackupDirectory $backup -Force | Out-Null
Assert ((Get-FileHash $target).Hash -eq $hash) 'Restore failed to reproduce original bytes.'
Assert (@(Get-ChildItem -LiteralPath $backup -Filter 'before-restore-*.js').Count -eq 1) 'Current edits were not saved.'
$bad=$false
try { & $install -DomesticInterface 'Test Ethernet' -OverseasInterface 'Test Ethernet' -ConfigDirectory $config -StateDirectory $state | Out-Null } catch { $bad=$true }
Assert $bad 'Same-interface input was accepted.'
Write-Output 'PASS: discovery, explicit portal routes, defaults, policy overrides, offline generation, deduplication, custom-script guard, install, escaping, backup, changed-file guard, restore, edit preservation, distinct adapters.'
Write-Output "Temporary test files: $root"

$strictState = Join-Path $root 'strict'
& $install -DomesticInterface 'Test Ethernet' -OverseasInterface 'Test Wi-Fi' -StateDirectory $strictState -SkipNetworkDiscovery -RuleMode strict | Out-Null
$strictFile = Get-ChildItem -LiteralPath $strictState -Filter Script.js -Recurse | Select-Object -First 1
Assert ((Read-GeneratedOptions $strictFile.FullName).ruleMode -eq 'strict') 'Strict mode was lost.'
@'
const fs=require('fs'), vm=require('vm'), assert=require('node:assert/strict');
vm.runInThisContext(fs.readFileSync(process.argv[2],'utf8'));
const output=main({proxies:[{name:'Example',type:'ss',server:'192.0.2.1',port:443}],rules:['MATCH,DIRECT']});
assert.equal(output.tun['strict-route'],true);
assert.equal(output.ipv6,false);
assert(output.rules.some(r=>r.startsWith('GEOSITE,geolocation-!cn,')));
assert(!output.rules.includes('MATCH,DIRECT'));
'@ | & node - $strictFile.FullName
Assert ($LASTEXITCODE -eq 0) 'Strict generated script integration failed.'
$invalidStrict = $false
try { & $install -DomesticInterface 'Test Ethernet' -OverseasInterface 'Test Wi-Fi' -StateDirectory $strictState -RuleMode strict -ProxyIpVersion dual | Out-Null } catch { $invalidStrict = $true }
Assert $invalidStrict 'Strict accepted a conflicting IP version.'
Write-Output 'PASS: strict mode generation, execution, and IP-version validation.'
