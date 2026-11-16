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
$global:fallbackOwnedSupervisorActive = $false
$global:fallbackSupervisorQueries = 0
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
    if ($Filter -eq "Name = 'powershell.exe'") {
        $global:fallbackSupervisorQueries++
        if ($global:fallbackOwnedSupervisorActive) {
            Assert (Test-Path -LiteralPath (Join-Path $global:fallbackExpectedState 'stop.request.json')) 'Request cooperative stop before waiting for the supervisor.'
            $global:fallbackOwnedSupervisorActive = $false
            $supervisorExecutable = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
            $supervisorArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $global:fallbackExpectedState 'launch.ps1') + '"'
            [pscustomobject]@{ ExecutablePath=$supervisorExecutable; CommandLine=('"' + $supervisorExecutable + '" ' + $supervisorArgs) }
        }
        return
    }
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
    Assert ($FilePath -eq (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -and $WindowStyle -eq 'Hidden') 'Launch the persistent PowerShell supervisor hidden.'
    $expected = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $global:fallbackExpectedState 'launch.ps1') + '"'
    Assert ($ArgumentList -eq $expected) 'Quote the supervisor filesystem argument exactly.'
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
$launcherPath = Join-Path $state 'launch.ps1'
$supervisorStop = Join-Path $state 'stop.request.json'
$supervisorStderr = Join-Path $state 'watcher-stderr.log'
$supervisorLog = Join-Path $state 'supervisor.log'
$launchText = [IO.File]::ReadAllText($launcherPath)
$mutexName = [regex]::Match($launchText, "Local\\ClashDualNicSupervisor-[A-F0-9]+").Value
Assert ($mutexName.Length -gt 0) 'Generated supervisor uses a stable installation mutex.'
$heldMutex = New-Object Threading.Mutex($false, $mutexName)
Assert ($heldMutex.WaitOne(0)) 'Acquire the installation supervisor mutex for the duplicate launch test.'
$duplicateMarker = Join-Path $state 'duplicate-start.marker'
$runspace = [PowerShell]::Create()
try {
    [void]$runspace.AddScript({
        param($launcherPath, $supervisorStop, $duplicateMarker)
        function Start-Process {
            param($FilePath, $WindowStyle, $ArgumentList, $RedirectStandardError, [switch]$Wait, [switch]$PassThru)
            [IO.File]::WriteAllText($duplicateMarker, 'started')
            [IO.File]::WriteAllText($supervisorStop, '{}')
            [pscustomobject]@{ExitCode=0}
        }
        & $launcherPath
    }).AddArgument($launcherPath).AddArgument($supervisorStop).AddArgument($duplicateMarker)
    $null = $runspace.Invoke()
    Assert ($runspace.Streams.Error.Count -eq 0) 'Duplicate supervisor exits cleanly.'
    Assert (-not (Test-Path -LiteralPath $duplicateMarker)) 'An existing supervisor prevents duplicate child launches across threads.'
} finally {
    $runspace.Dispose()
    $heldMutex.ReleaseMutex()
    $heldMutex.Dispose()
}
foreach ($scenario in @('exited-child', 'failed-start', 'stop-during-delay')) {
    & {
        $global:supervisorCalls = 0
        $global:supervisorWaits = 0
        [IO.File]::WriteAllText($supervisorStderr, ('x' * 262145))
        [IO.File]::WriteAllText($supervisorLog, '')
        function Start-Process {
            param($FilePath, $WindowStyle, $ArgumentList, $RedirectStandardError, [switch]$Wait, [switch]$PassThru)
            Assert ($FilePath -eq $global:fallbackNode -and $WindowStyle -eq 'Hidden' -and $Wait -and $PassThru) 'Supervisor waits on the exact hidden Node child.'
            $expected = '"' + (Join-Path $state 'watch-fallback.cjs') + '" --config "' + (Join-Path $state 'config.json') + '"'
            Assert ($ArgumentList -eq $expected -and $RedirectStandardError -eq $supervisorStderr) 'Child arguments and diagnostics preserve special paths.'
            $global:supervisorCalls++
            Assert ($global:supervisorCalls -le 2) 'Restart loop is bounded by the test stop request.'
            if ($scenario -eq 'failed-start' -and $global:supervisorCalls -eq 1) { throw 'simulated child start failure' }
            if ($global:supervisorCalls -eq 2) { [IO.File]::WriteAllText($supervisorStop, '{}') }
            [pscustomobject]@{ Id=12345; ExitCode=1 }
        }
        function Start-Sleep {
            param($Milliseconds)
            Assert ($Milliseconds -le 500) 'Supervisor stop polling has at most 500 ms delay.'
            $global:supervisorWaits++
            if ($scenario -eq 'stop-during-delay') { [IO.File]::WriteAllText($supervisorStop, '{}') }
        }
        & $launcherPath
        Assert ((Get-Item -LiteralPath ($supervisorStderr + '.last')).Length -eq 262145) 'Supervisor rotates oversized stderr before starting a child.'
        if ($scenario -eq 'stop-during-delay') {
            Assert ($global:supervisorCalls -eq 1 -and $global:supervisorWaits -eq 1) 'A stop request interrupts the restart delay.'
        } else {
            Assert ($global:supervisorCalls -eq 2 -and $global:supervisorWaits -eq 10) 'An exited or failed child restarts after a five second retry delay.'
        }
        if ($scenario -eq 'failed-start') { Assert ([IO.File]::ReadAllText($supervisorStderr).Contains('simulated child start failure')) 'Supervisor captures child start errors.' }
        $events = @(Get-Content -LiteralPath $supervisorLog | ForEach-Object { $_ | ConvertFrom-Json })
        $lastEvent = $events[-1]
        Assert ($lastEvent.event -eq 'child-exited' -and $lastEvent.childPid -eq 12345 -and $lastEvent.exitCode -eq 1 -and $lastEvent.occurredAt) 'Supervisor records child exit time, PID and exit code.'
        if ($scenario -eq 'failed-start') { Assert ($events[0].event -eq 'start-failed') 'Supervisor records startup failure and then recovers.' }
        Remove-Item -LiteralPath $supervisorStop
    }
}
$configHash = (Get-FileHash -LiteralPath (Join-Path $state 'config.json')).Hash
Invoke-Install -WhatIf | Out-Null
Assert ($global:fallbackStarts -eq 1 -and $configHash -eq (Get-FileHash -LiteralPath (Join-Path $state 'config.json')).Hash) 'Update WhatIf preserves running installation.'
$global:fallbackOwnedProcessActive = $true
$global:fallbackOwnedSupervisorActive = $true
Invoke-Install | Out-Null
$updated = Read-Manifest
Assert ($updated.originalStartupValue -eq $manifest.originalStartupValue -and $global:fallbackStarts -eq 2) 'Update preserves original baseline and restarts watcher.'
Assert (@(Get-ChildItem -LiteralPath $state -Directory -Filter 'backup-*').Count -eq 1) 'Update keeps one local copy of previous artifacts.'
Assert ($global:fallbackProcessQueries -gt 0) 'Update checks completion of its stop request.'
Assert ($global:fallbackSupervisorQueries -ge 2) 'Update waits for its exact supervisor to finish before replacing the stop sentinel.'
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
try { & $tool -DomesticInterface 'Campus [1]' -OverseasInterface 'Wi-Fi *' -StateDirectory $state | Out-Null } catch { $caught = $true }
Assert $caught 'Overseas adapter matching must use literal names.'
$global:fallbackAdapters = @([pscustomobject]@{Name="Wi-Fi O'Brien"; Status='Up'})
& $tool -DomesticInterface 'Campus [1]' -OverseasInterface "Wi-Fi O'Brien" -StateDirectory $state | Out-Null
Write-Output 'PASS: fallback preview, WhatIf, disconnected and absent campus adapters, literal names, hidden supervisor, crash and startup failure recovery, interruptible stop, mutex exclusion, stderr rotation, startup baseline, backups and uninstall ownership.'
Write-Output "Temporary test files: $root"
