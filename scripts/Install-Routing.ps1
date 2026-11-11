[CmdletBinding()]
param(
    [string]$DomesticInterface,
    [string]$OverseasInterface,
    [string]$PreferredProxy = '',
    [ValidateSet('preserve', 'replace', 'strict')][string]$RuleMode = 'preserve',
    [ValidateSet('ipv4', 'dual', 'ipv6', 'ipv4-prefer', 'ipv6-prefer')][string]$ProxyIpVersion = 'ipv4',
    [string[]]$ExtraDirectDomains = @(),
    [string[]]$ExtraDirectCidrs = @(),
    [switch]$SkipNetworkDiscovery,
    [string]$ConfigDirectory = (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'),
    [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'clash-dual-nic-router'),
    [switch]$Install,
    [switch]$ReplaceExisting,
    [switch]$ListAdapters
)
$ErrorActionPreference = 'Stop'
if ($ListAdapters) {
    Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed
    return
}
if ([string]::IsNullOrWhiteSpace($DomesticInterface) -or [string]::IsNullOrWhiteSpace($OverseasInterface)) {
    throw 'Supply -DomesticInterface and -OverseasInterface. Use -ListAdapters to list adapter names.'
}
if ($DomesticInterface -eq $OverseasInterface) { throw 'Choose two different network adapters.' }
foreach ($name in @($DomesticInterface, $OverseasInterface)) {
    $adapter = @(Get-NetAdapter | Where-Object Name -eq $name)
    if ($adapter.Count -ne 1 -or $adapter[0].Status -ne 'Up') { throw "Connect the network adapter first: $name" }
}
if ($RuleMode -eq 'strict' -and $ProxyIpVersion -ne 'ipv4') { throw 'Strict mode requires -ProxyIpVersion ipv4.' }
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'split-routing.js'
$text = [IO.File]::ReadAllText($source)
# Keep the domestic adapter's DNS and gateways reachable outside TUN, including
# campus DNS or authentication gateways with public addresses. Portal domains
# and other portal addresses are supplied explicitly by the user.
$directCidrs = @($ExtraDirectCidrs)
if (-not $SkipNetworkDiscovery) {
    $dnsAddresses = @(Get-DnsClientServerAddress -InterfaceAlias $DomesticInterface | ForEach-Object { $_.ServerAddresses })
    $network = Get-NetIPConfiguration -InterfaceAlias $DomesticInterface
    $gatewayAddresses = @($network.IPv4DefaultGateway.NextHop) + @($network.IPv6DefaultGateway.NextHop)
    foreach ($address in @($dnsAddresses) + @($gatewayAddresses)) {
        if ([string]::IsNullOrWhiteSpace($address)) { continue }
        $ip = $null
        # CIDRs contain addresses without an adapter's IPv6 scope identifier.
        if (-not [Net.IPAddress]::TryParse(($address -split '%')[0], [ref]$ip)) { throw "Invalid discovered DNS or gateway address: $address" }
        if ($ip.Equals([Net.IPAddress]::Any) -or $ip.Equals([Net.IPAddress]::IPv6Any)) { continue }
        $prefix = if ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { 32 } else { 128 }
        $directCidrs += "$($ip.ToString())/$prefix"
    }
}
$directCidrs = @($directCidrs | Select-Object -Unique)
$options = [ordered]@{
    domesticInterface=$DomesticInterface
    overseasInterface=$OverseasInterface
    preferredProxy=$PreferredProxy
    tun=$true
    ruleMode=$RuleMode
    proxyIpVersion=$ProxyIpVersion
    extraDirectDomains=@($ExtraDirectDomains | Select-Object -Unique)
    extraDirectCidrs=$directCidrs
}
$replacement = "// BEGIN USER OPTIONS`nconst OPTIONS = " + ($options | ConvertTo-Json -Depth 4) + ";`n// END USER OPTIONS"
$pattern = '(?s)// BEGIN USER OPTIONS.*?// END USER OPTIONS'
if ([regex]::Matches($text, $pattern).Count -ne 1) { throw 'Expected one USER OPTIONS block in split-routing.js.' }
$text = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement })
$utf8 = New-Object System.Text.UTF8Encoding($false)
$stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$state = Join-Path ([IO.Path]::GetFullPath($StateDirectory)) $stamp
New-Item -ItemType Directory -Path $state -Force | Out-Null
$generated = Join-Path $state 'Script.js'
[IO.File]::WriteAllText($generated, $text, $utf8)
if (-not $Install) { Write-Output "Generated: $generated"; return }
$target = Join-Path ([IO.Path]::GetFullPath($ConfigDirectory)) 'profiles\Script.js'
if (-not (Test-Path -LiteralPath (Split-Path $target -Parent) -PathType Container)) { throw 'Choose an existing Clash Verge configuration directory.' }
$exists = Test-Path -LiteralPath $target -PathType Leaf
if ($exists) {
    $old = [IO.File]::ReadAllText($target)
    $template = $old -replace '(?m)//[^\r\n]*','' -replace '\s',''
    $known = $old.Contains('// Dual NIC Router - managed script') -or ($template -in @('functionmain(config,profileName){returnconfig;}','functionmain(config){returnconfig;}',''))
    if (-not $known -and -not $ReplaceExisting) { throw 'An existing custom script is present. Review it and use -ReplaceExisting to replace it with a saved backup.' }
    Copy-Item -LiteralPath $target -Destination (Join-Path $state 'original.js')
}
$manifest = [ordered]@{ version=1; target=$target; hadOriginal=$exists; installedSha256=$null }
# Write through a sibling file so a partial write leaves the active script intact.
$temp = "$target.$stamp.tmp"
[IO.File]::WriteAllText($temp,$text,$utf8)
$manifest.installedSha256 = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
[IO.File]::WriteAllText((Join-Path $state 'manifest.json'),($manifest | ConvertTo-Json),$utf8)
if ($exists) { [IO.File]::Replace($temp,$target,[System.Management.Automation.Language.NullString]::Value) } else { [IO.File]::Move($temp,$target) }
Write-Output "Installed: $target"
Write-Output "Backup: $state"
Write-Output 'Open Clash Verge, save the global extension script, select Rule mode, and enable TUN.'
