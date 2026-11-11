# Run -Apply or -RestoreFrom in an administrator PowerShell session.
# A plain invocation previews the selected adapter's IPv6 binding.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Preview')]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$InterfaceAlias,
    [Parameter(ParameterSetName = 'Apply')][switch]$Apply,
    [Parameter(Mandatory = $true, ParameterSetName = 'Restore')][ValidateNotNullOrEmpty()][string]$RestoreFrom,
    [Parameter(ParameterSetName = 'Apply')][string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'clash-dual-nic-router')
)
$ErrorActionPreference = 'Stop'
# The named helper also lets the isolated tests supply a simulated privilege state.
if (-not (Get-Command Test-IPv4OnlyAdministrator -CommandType Function -ErrorAction SilentlyContinue)) {
    function Test-IPv4OnlyAdministrator {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $principal = New-Object Security.Principal.WindowsPrincipal($identity)
            return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } finally { $identity.Dispose() }
    }
}
$adapters = @(Get-NetAdapter | Where-Object { $_.Name -eq $InterfaceAlias })
if ($adapters.Count -ne 1) { throw "Choose an existing, uniquely named adapter: $InterfaceAlias" }
$adapter = $adapters[0]
$adapterGuid = [guid]$adapter.InterfaceGuid
# Query all adapters, then use literal equality; names containing [] remain literal.
$bindings = @(Get-NetAdapterBinding -ComponentID 'ms_tcpip6' | Where-Object { $_.Name -eq $adapter.Name })
if ($bindings.Count -ne 1) { throw "Expected one IPv6 binding for adapter: $InterfaceAlias" }
$binding = $bindings[0]
if ($binding.Enabled -isnot [bool]) { throw 'Expected a Boolean IPv6 binding state.' }
if ($PSCmdlet.ParameterSetName -eq 'Preview' -or ($PSCmdlet.ParameterSetName -eq 'Apply' -and -not $Apply)) {
    [pscustomobject]@{ InterfaceAlias = $adapter.Name; InterfaceGuid = $adapterGuid.ToString(); IPv6Enabled = $binding.Enabled; Mode = 'Preview' }
    return
}
$desiredEnabled = $false
$manifestPath = $null
if ($PSCmdlet.ParameterSetName -eq 'Restore') {
    $manifestPath = [IO.Path]::GetFullPath($RestoreFrom)
    $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($manifest.version -ne 1 -or $manifest.kind -ne 'adapter-ipv6-binding' -or $manifest.previousEnabled -isnot [bool]) {
        throw 'Choose a version 1 adapter IPv6 binding backup.'
    }
    $savedGuid = [guid]$manifest.interfaceGuid
    if ($savedGuid -ne $adapterGuid) { throw 'The backup adapter GUID must match the selected adapter.' }
    $desiredEnabled = $manifest.previousEnabled
}
$action = if ($PSCmdlet.ParameterSetName -eq 'Restore') { "Restore IPv6 binding to $desiredEnabled" } else { 'Save IPv6 binding state and disable IPv6 binding' }
if (-not $PSCmdlet.ShouldProcess("$($adapter.Name) ($adapterGuid)", $action)) { return }
if (-not (Test-IPv4OnlyAdministrator)) { throw 'Run this operation in an administrator PowerShell session.' }
if ($PSCmdlet.ParameterSetName -eq 'Apply') {
    $statePath = [IO.Path]::GetFullPath($StateDirectory)
    [IO.Directory]::CreateDirectory($statePath) | Out-Null
    $manifestPath = Join-Path $statePath ('ipv6-binding-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.json')
    $manifest = [ordered]@{
        version = 1
        kind = 'adapter-ipv6-binding'
        interfaceGuid = $adapterGuid.ToString()
        interfaceAlias = $adapter.Name
        previousEnabled = $binding.Enabled
        createdUtc = [DateTime]::UtcNow.ToString('o')
    }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($manifest | ConvertTo-Json))
    # CreateNew preserves every prior backup. Flush the backup before changing Windows.
    $stream = [IO.File]::Open($manifestPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
if ($binding.Enabled -ne $desiredEnabled) {
    if ($desiredEnabled) {
        Enable-NetAdapterBinding -InputObject $binding -Confirm:$false -ErrorAction Stop | Out-Null
    } else {
        Disable-NetAdapterBinding -InputObject $binding -Confirm:$false -ErrorAction Stop | Out-Null
    }
}
[pscustomobject]@{
    InterfaceAlias = $adapter.Name
    InterfaceGuid = $adapterGuid.ToString()
    IPv6Enabled = $desiredEnabled
    Mode = $PSCmdlet.ParameterSetName
    Backup = $manifestPath
}
