$ErrorActionPreference = 'Stop'
$tool = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Set-AdapterIPv4Only.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('dual-nic-ipv6-' + [guid]::NewGuid().ToString('N'))
$state = Join-Path $root '中文备份目录'
# Every Windows network command is a function mock; only temporary files are real.
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = [IO.Path]::GetTempPath() }
$global:ipv4TestAdapter = [pscustomobject]@{ Name = 'Wi-Fi [2]'; InterfaceGuid = [guid]::NewGuid().ToString() }
$global:ipv4TestBinding = [pscustomobject]@{ Name = $global:ipv4TestAdapter.Name; ComponentID = 'ms_tcpip6'; Enabled = $true }
$global:ipv4TestAdmin = $true
$global:ipv4TestChanges = 0
$global:ipv4TestRequireBackup = $false
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Test-IPv4OnlyAdministrator { return $global:ipv4TestAdmin }
function Get-NetAdapter {
    $global:ipv4TestAdapter
    [pscustomobject]@{ Name = 'Wi-Fi 2'; InterfaceGuid = [guid]::NewGuid().ToString() }
}
function Get-NetAdapterBinding {
    param([string]$ComponentID)
    Assert ($ComponentID -eq 'ms_tcpip6') 'Expected the IPv6 component.'
    $global:ipv4TestBinding
    [pscustomobject]@{ Name = 'Wi-Fi 2'; ComponentID = 'ms_tcpip6'; Enabled = $true }
}
function Disable-NetAdapterBinding {
    [CmdletBinding(SupportsShouldProcess = $true)]param($InputObject)
    Assert ([object]::ReferenceEquals($InputObject, $global:ipv4TestBinding)) 'Expected the exact selected binding object.'
    if ($global:ipv4TestRequireBackup) {
        $files = @(Get-ChildItem -LiteralPath $state -Filter 'ipv6-binding-*.json')
        Assert ($files.Count -gt 0) 'The original state must be saved before the binding changes.'
        $saved = [IO.File]::ReadAllText($files[-1].FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert ($saved.previousEnabled -eq $true) 'Backup must contain the pre-change state.'
        Assert ($saved.interfaceGuid -eq $global:ipv4TestAdapter.InterfaceGuid) 'Backup GUID must identify the selected adapter.'
    }
    $global:ipv4TestChanges++
    $global:ipv4TestBinding.Enabled = $false
}
function Enable-NetAdapterBinding {
    [CmdletBinding(SupportsShouldProcess = $true)]param($InputObject)
    Assert ([object]::ReferenceEquals($InputObject, $global:ipv4TestBinding)) 'Expected the exact selected binding object.'
    $global:ipv4TestChanges++
    $global:ipv4TestBinding.Enabled = $true
}
$preview = & $tool -InterfaceAlias $global:ipv4TestAdapter.Name -StateDirectory $state
Assert ($preview.IPv6Enabled -eq $true -and $preview.Mode -eq 'Preview') 'Preview must expose the current state.'
Assert ($global:ipv4TestChanges -eq 0 -and -not (Test-Path -LiteralPath $root)) 'Preview must preserve files and adapters.'
& $tool -InterfaceAlias $global:ipv4TestAdapter.Name -StateDirectory $state -Apply -WhatIf | Out-Null
Assert ($global:ipv4TestChanges -eq 0 -and -not (Test-Path -LiteralPath $root)) 'WhatIf must preserve files and adapters.'
$global:ipv4TestAdmin = $false
$caught = $false
try { & $tool -InterfaceAlias $global:ipv4TestAdapter.Name -StateDirectory $state -Apply | Out-Null } catch { $caught = $_.Exception.Message -like '*administrator*' }
Assert $caught 'Applying requires administrator privileges.'
Assert ($global:ipv4TestChanges -eq 0 -and -not (Test-Path -LiteralPath $root)) 'Privilege rejection must precede file changes.'
$global:ipv4TestAdmin = $true
$global:ipv4TestRequireBackup = $true
$applied = & $tool -InterfaceAlias $global:ipv4TestAdapter.Name -StateDirectory $state -Apply
$originalBackup = $applied.Backup
$backupBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($originalBackup))
Assert ($global:ipv4TestChanges -eq 1 -and $global:ipv4TestBinding.Enabled -eq $false) 'Applying must disable the chosen binding.'
Assert ($applied.Backup.StartsWith($state)) 'The Chinese backup path must be preserved.'
$global:ipv4TestRequireBackup = $false
$again = & $tool -InterfaceAlias $global:ipv4TestAdapter.Name -StateDirectory $state -Apply
Assert ($again.Backup -ne $originalBackup) 'Each apply must have a unique backup.'
$disabledBackup = [IO.File]::ReadAllText($again.Backup, [Text.Encoding]::UTF8) | ConvertFrom-Json
Assert ($disabledBackup.previousEnabled -eq $false -and $global:ipv4TestChanges -eq 1) 'An already disabled binding must retain its original state.'
$global:ipv4TestBinding.Enabled = $true
& $tool -InterfaceAlias $global:ipv4TestAdapter.Name -RestoreFrom $again.Backup | Out-Null
Assert ($global:ipv4TestBinding.Enabled -eq $false -and $global:ipv4TestChanges -eq 2) 'Restoring a disabled baseline must disable the binding.'
& $tool -InterfaceAlias $global:ipv4TestAdapter.Name -RestoreFrom $originalBackup -WhatIf | Out-Null
Assert ($global:ipv4TestBinding.Enabled -eq $false -and $global:ipv4TestChanges -eq 2) 'Restore WhatIf must retain binding state.'
$originalGuid = $global:ipv4TestAdapter.InterfaceGuid
$global:ipv4TestAdapter.InterfaceGuid = [guid]::NewGuid().ToString()
$caught = $false
try { & $tool -InterfaceAlias $global:ipv4TestAdapter.Name -RestoreFrom $originalBackup | Out-Null } catch { $caught = $_.Exception.Message -like '*GUID*' }
Assert ($caught -and $global:ipv4TestChanges -eq 2) 'Restore must validate the adapter GUID.'
$global:ipv4TestAdapter.InterfaceGuid = $originalGuid
$global:ipv4TestAdmin = $false
$caught = $false
try { & $tool -InterfaceAlias $global:ipv4TestAdapter.Name -RestoreFrom $originalBackup | Out-Null } catch { $caught = $_.Exception.Message -like '*administrator*' }
Assert ($caught -and $global:ipv4TestChanges -eq 2) 'Restore requires administrator privileges.'
$global:ipv4TestAdmin = $true
& $tool -InterfaceAlias $global:ipv4TestAdapter.Name -RestoreFrom $originalBackup | Out-Null
Assert ($global:ipv4TestBinding.Enabled -eq $true -and $global:ipv4TestChanges -eq 3) 'Restore must recover the enabled baseline.'
& $tool -InterfaceAlias $global:ipv4TestAdapter.Name -RestoreFrom $originalBackup | Out-Null
Assert ($global:ipv4TestChanges -eq 3) 'Repeated restore must be idempotent.'
Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($originalBackup)) -eq $backupBytes) 'Restore must preserve original backup bytes.'
$caught = $false
try { & $tool -InterfaceAlias $global:ipv4TestAdapter.Name -Apply -RestoreFrom $originalBackup | Out-Null } catch { $caught = $true }
Assert ($caught -and $global:ipv4TestChanges -eq 3) 'Apply and restore must be mutually exclusive.'
$caught = $false
try { & $tool -InterfaceAlias 'Wi-Fi *' | Out-Null } catch { $caught = $true }
Assert $caught 'Adapter names must use literal equality.'
$badPath = Join-Path $state 'bad-version.json'
$bad = [IO.File]::ReadAllText($originalBackup, [Text.Encoding]::UTF8) | ConvertFrom-Json
$bad.version = 2
[IO.File]::WriteAllText($badPath, ($bad | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
$caught = $false
try { & $tool -InterfaceAlias $global:ipv4TestAdapter.Name -RestoreFrom $badPath | Out-Null } catch { $caught = $true }
Assert ($caught -and $global:ipv4TestChanges -eq 3) 'Restore must validate manifest version.'
Write-Output 'PASS: preview, apply/restore WhatIf, administrator checks, exact binding selection, backup-before-disable, unique backups, disabled baseline, Chinese paths, GUID/version checks, repeatable restore, original backup preservation, mutually exclusive operations.'
Write-Output "Temporary test files: $root"
