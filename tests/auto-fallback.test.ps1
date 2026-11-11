$ErrorActionPreference = 'Stop'
$tool = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Install-AutoFallback.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('dual-nic-fallback-' + [guid]::NewGuid().ToString('N'))
$state = Join-Path $root "中文 [状态] O'Brien"
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = [IO.Path]::GetTempPath() }
if (-not $env:SystemRoot) { $env:SystemRoot = $root }
$global:fallbackRegistryExists = $true
$global:fallbackRegistryValue = 'original unrelated startup'
$global:fallbackRegistryChanges = 0
$global:fallbackStarts = 0
$global:fallbackProcessQueries = 0
$global:fallbackOwnedProcessActive = $false
$global:fallbackWaits = 0
$global:fallbackNode = Join-Path $root "Node O'Brien/node.exe"
$global:fallbackExpectedState = $state
$global:fallbackAdapters = @([pscustomobject]@{Name='Campus [1]'; Status='Disconnected'}, [pscustomobject]@{Name='Wi-Fi O''Brien'; Status='Up'})
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Get-NetAdapter { $global:fallbackAdapters }
function Test-Path {
    param($LiteralPath, $PathType)
    if ($LiteralPath -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') { return $true }
    if ($PathType) { Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType }
    else { Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath }
}
function Get-Command {
    param($Name, $CommandType, $ErrorAction)
    Assert ($Name -eq 'node') 'Only Node lookup is expected.'
    [pscustomobject]@{ Source=$global:fallbackNode }
    [pscustomobject]@{ Source=(Join-Path $root 'second-node/node.exe') }
}
function Get-ItemProperty {
    param($LiteralPath, $ErrorAction)
    Assert ($LiteralPath -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') 'Expected the dedicated startup registry path.'
    if ($global:fallbackRegistryExists) { [pscustomobject]@{ ClashDualNicAutoFallback = $global:fallbackRegistryValue } } else { [pscustomobject]@{} }
}
function New-Item {
    param($Path, $ItemType, [switch]$Force)
    if ($Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') { return }
    Microsoft.PowerShell.Management\New-Item -Path $Path -ItemType $ItemType -Force:$Force
}
function New-ItemProperty {
    param($LiteralPath, $Name, $Value, $PropertyType, [switch]$Force)
    Assert ($Name -eq 'ClashDualNicAutoFallback') 'Only the owned startup property may change.'
    Assert (Test-Path -LiteralPath (Join-Path $global:fallbackExpectedState 'install-manifest.json')) 'Save baseline before changing startup.'
    $global:fallbackRegistryExists = $true
    $global:fallbackRegistryValue = $Value
    $global:fallbackRegistryChanges++
}
function Remove-ItemProperty {
    param($LiteralPath, $Name)
    Assert ($Name -eq 'ClashDualNicAutoFallback') 'Only the owned startup property may be removed.'
    $global:fallbackRegistryExists = $false
    $global:fallbackRegistryValue = $null
    $global:fallbackRegistryChanges++
}
function Get-CimInstance {
    param($ClassName, $Filter)
    Assert ($ClassName -eq 'Win32_Process') 'Expected the Windows process inventory.'
    $global:fallbackProcessQueries++
    if ($global:fallbackOwnedProcessActive) {
        Assert (Test-Path -LiteralPath (Join-Path $global:fallbackExpectedState 'stop.request.json')) 'Stop must be requested before waiting for the owned process.'
        $global:fallbackOwnedProcessActive = $false
        $ownedArgs = '"' + (Join-Path $global:fallbackExpectedState 'watch-fallback.cjs') + '" --config "' + (Join-Path $global:fallbackExpectedState 'config.json') + '"'
        [pscustomobject]@{ ExecutablePath=$global:fallbackNode; CommandLine=('"' + $global:fallbackNode + '" ' + $ownedArgs) }
    }
    # Deliberately unrelated Node process with a similar prefix: never stop it.
    [pscustomobject]@{ ExecutablePath=$global:fallbackNode; CommandLine='node unrelated-script.cjs --config "other/config.json"' }
}
function Start-Sleep { param($Milliseconds); $global:fallbackWaits++ }
function Start-Process {
    param($FilePath, $WindowStyle, $ArgumentList)
    Assert ($FilePath -eq $global:fallbackNode -and $WindowStyle -eq 'Hidden') 'Launch exact Node executable hidden.'
    $expected = '"' + (Join-Path $global:fallbackExpectedState 'watch-fallback.cjs') + '" --config "' + (Join-Path $global:fallbackExpectedState 'config.json') + '"'
    Assert ($ArgumentList -eq $expected) 'Quote each Node filesystem argument exactly.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $global:fallbackExpectedState 'stop.request.json'))) 'Clear stop sentinel before launch.'
    $global:fallbackStarts++
}
function Read-Manifest { [IO.File]::ReadAllText((Join-Path $state 'install-manifest.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json }
function Invoke-Install { & $tool -DomesticInterface 'Campus [1]' -OverseasInterface "Wi-Fi O'Brien" -StateDirectory $state -Install @args }

Invoke-Install -WhatIf | Out-Null
Assert (-not (Test-Path -LiteralPath $root)) 'Install WhatIf must preserve the filesystem.'
Assert ($global:fallbackStarts -eq 0 -and $global:fallbackRegistryChanges -eq 0) 'WhatIf must preserve processes and registry.'
& $tool -DomesticInterface 'Campus [1]' -OverseasInterface "Wi-Fi O'Brien" -StateDirectory $state | Out-Null
Assert ($global:fallbackStarts -eq 0 -and $global:fallbackRegistryChanges -eq 0) 'Preview generates files only.'
Assert (-not (Test-Path -LiteralPath (Join-Path $state 'config.json'))) 'Preview must leave installed config untouched.'
Invoke-Install | Out-Null
$manifest = Read-Manifest
Assert ($manifest.originalStartupExists -and $manifest.originalStartupValue -eq 'original unrelated startup') 'Capture original startup value.'
Assert ($manifest.installed -and $global:fallbackStarts -eq 1) 'Install starts the watcher.'
Assert ($manifest.nodePath -is [string] -and $manifest.nodePath -eq $global:fallbackNode) 'Multiple Node commands resolve to the first executable.'
$config = [IO.File]::ReadAllText((Join-Path $state 'config.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
Assert ($config.domesticInterface -eq 'Campus [1]' -and $config.overseasInterface -eq "Wi-Fi O'Brien") 'Disconnected domestic adapter and literal special names are supported.'
Assert ($config.pipeName -eq 'verge-mihomo' -and $config.intervalSeconds -eq 5 -and $config.recoverySamples -eq 3) 'Expected watcher defaults.'
$tokens = $null; $errors = $null
[Management.Automation.Language.Parser]::ParseFile((Join-Path $state 'launch.ps1'), [ref]$tokens, [ref]$errors) | Out-Null
Assert ($errors.Count -eq 0) 'Generated launcher must parse with apostrophes and Unicode paths.'
$configHash = (Get-FileHash -LiteralPath (Join-Path $state 'config.json')).Hash
Invoke-Install -WhatIf | Out-Null
Assert ($global:fallbackStarts -eq 1 -and $configHash -eq (Get-FileHash -LiteralPath (Join-Path $state 'config.json')).Hash) 'Update WhatIf preserves running installation.'
$global:fallbackOwnedProcessActive = $true
Invoke-Install | Out-Null
$updated = Read-Manifest
Assert ($updated.originalStartupValue -eq $manifest.originalStartupValue -and $global:fallbackStarts -eq 2) 'Update preserves original baseline and restarts watcher.'
Assert (@(Get-ChildItem -LiteralPath $state -Directory -Filter 'backup-*').Count -eq 1) 'Update keeps one local copy of previous artifacts.'
Assert ($global:fallbackProcessQueries -gt 0) 'Update checks completion of its stop request.'
Assert ($global:fallbackWaits -eq 1) 'Update waits for the matching watcher to finish before restarting.'
$changes = $global:fallbackRegistryChanges
& $tool -Uninstall -StateDirectory $state -WhatIf | Out-Null
Assert ($global:fallbackRegistryChanges -eq $changes -and -not (Test-Path -LiteralPath (Join-Path $state 'stop.request.json'))) 'Uninstall WhatIf preserves startup and stop state.'
& $tool -Uninstall -StateDirectory $state | Out-Null
Assert ($global:fallbackRegistryValue -eq 'original unrelated startup') 'Uninstall restores startup baseline.'
Assert (Test-Path -LiteralPath (Join-Path $state 'stop.request.json')) 'Uninstall sends the cooperative stop request.'
$changes = $global:fallbackRegistryChanges
& $tool -Uninstall -StateDirectory $state | Out-Null
Assert ($global:fallbackRegistryChanges -eq $changes) 'Repeated uninstall is idempotent.'
$global:fallbackRegistryExists = $false
$global:fallbackRegistryValue = $null
Invoke-Install | Out-Null
Assert (-not (Read-Manifest).originalStartupExists) 'Reinstall after uninstall captures the fresh baseline.'
& $tool -Uninstall -StateDirectory $state | Out-Null
Assert (-not $global:fallbackRegistryExists) 'Uninstall removes startup when original was absent.'
Invoke-Install | Out-Null
$global:fallbackRegistryValue = 'externally replaced startup'
$caught = $false
try { Invoke-Install | Out-Null } catch { $caught = $_.Exception.Message -like '*externally*' }
Assert $caught 'Update must detect changed startup ownership.'
& $tool -Uninstall -StateDirectory $state | Out-Null
Assert ($global:fallbackRegistryValue -eq 'externally replaced startup') 'Uninstall preserves external startup edits.'
$caught = $false
try { & $tool -DomesticInterface 'Campus *' -OverseasInterface "Wi-Fi O'Brien" -StateDirectory $state | Out-Null } catch { $caught = $true }
Assert $caught 'Adapter matching must use literal names.'
Write-Output 'PASS: fallback preview, WhatIf, disconnected adapter, literal names, quoted hidden launch, startup baseline, repeat installation, backups, stop sentinel, uninstall ownership and repeatability.'
Write-Output "Temporary test files: $root"
