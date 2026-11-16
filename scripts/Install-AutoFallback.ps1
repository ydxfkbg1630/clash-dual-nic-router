[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Configure')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Configure')][string]$DomesticInterface,
    [Parameter(Mandatory = $true, ParameterSetName = 'Configure')][string]$OverseasInterface,
    [Parameter(ParameterSetName = 'Configure')][string]$PipeName = 'verge-mihomo',
    [Parameter(ParameterSetName = 'Configure')][ValidateRange(1, 300)][int]$IntervalSeconds = 5,
    [Parameter(ParameterSetName = 'Configure')][ValidateRange(1, 120)][int]$RecoverySamples = 3,
    [Parameter(ParameterSetName = 'Configure')][switch]$Install,
    [Parameter(Mandatory = $true, ParameterSetName = 'Uninstall')][switch]$Uninstall,
    [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'clash-dual-nic-router/auto-fallback')
)
$ErrorActionPreference = 'Stop'
$state = [IO.Path]::GetFullPath($StateDirectory)
$manifestPath = Join-Path $state 'install-manifest.json'
$registryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$registryName = 'ClashDualNicAutoFallback'
$utf8 = New-Object Text.UTF8Encoding($false)

function Read-Startup {
    $item = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
    $property = if ($null -ne $item) { $item.PSObject.Properties[$registryName] } else { $null }
    return [pscustomobject]@{ exists = ($null -ne $property); value = $(if ($null -ne $property) { [string]$property.Value } else { $null }) }
}
function Save-Json($Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8), $utf8)
}
function Get-OwnedWatcher($Manifest) {
    # The launcher always quotes both paths. Compare the exact executable and
    # argument suffix; adapter names and paths are never regex patterns.
    $suffix = '"' + $Manifest.watcherFile + '" --config "' + $Manifest.configFile + '"'
    @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" | Where-Object {
        $_.ExecutablePath -eq $Manifest.nodePath -and
        $null -ne $_.CommandLine -and $_.CommandLine.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)
    })
}
function Request-WatcherStop($Manifest) {
    Save-Json $Manifest.stopFile ([ordered]@{ requestedAt = [DateTime]::UtcNow.ToString('o') })
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(15, [int]$Manifest.intervalSeconds + 10))
    $supervisorPath = Join-Path (Split-Path $Manifest.configFile -Parent) 'launch.ps1'
    $supervisorSuffix = '-File "' + $supervisorPath + '"'
    $supervisorExecutable = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    do {
        $watchers = @(Get-OwnedWatcher $Manifest)
        $supervisors = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
            $_.ExecutablePath -eq $supervisorExecutable -and $null -ne $_.CommandLine -and
            $_.CommandLine.EndsWith($supervisorSuffix, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($watchers.Count -eq 0 -and $supervisors.Count -eq 0) { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'The watcher is finishing a request. Retry after it exits; the stop request remains saved.' }
        Start-Sleep -Milliseconds 250
    } while ($true)
}

if ($Uninstall) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Choose the installed state directory containing install-manifest.json.' }
    $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($manifest.version -ne 1 -or $manifest.stateDirectory -ne $state) { throw 'The installation manifest version or directory differs from this installation.' }
    if (-not $manifest.installed) { Write-Output 'Auto fallback is already uninstalled.'; return }
    $current = Read-Startup
    if ($PSCmdlet.ShouldProcess($state, 'Stop auto fallback and restore its saved login startup value')) {
        Request-WatcherStop $manifest
        if ($current.exists -and $current.value -eq $manifest.ownedStartupValue) {
            if ($manifest.originalStartupExists) {
                New-ItemProperty -LiteralPath $registryPath -Name $registryName -Value $manifest.originalStartupValue -PropertyType String -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath $registryPath -Name $registryName
            }
        }
        $manifest.installed = $false
        Save-Json $manifestPath $manifest
        Write-Output "Auto fallback stopped; startup restored where owned. Saved files: $state"
    }
    return
}

if ([string]::IsNullOrWhiteSpace($DomesticInterface) -or [string]::IsNullOrWhiteSpace($OverseasInterface) -or $DomesticInterface -eq $OverseasInterface) { throw 'Supply two distinct adapter names.' }
# A removable campus adapter may be absent throughout Wi-Fi fallback.
if (@(Get-NetAdapter | Where-Object Name -eq $OverseasInterface).Count -ne 1) { throw "Choose an existing overseas adapter by its exact name: $OverseasInterface" }
$node = Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1
$nodePath = $node.Source
$source = Join-Path $PSScriptRoot 'watch-fallback.cjs'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Keep this installer in the repository scripts directory beside watch-fallback.cjs.' }
$target = if ($Install) { $state } else { Join-Path $state ('previews/' + [guid]::NewGuid().ToString('N')) }
$configFile = Join-Path $target 'config.json'
$watcherFile = Join-Path $target 'watch-fallback.cjs'
$stopFile = Join-Path $target 'stop.request.json'
$launcherFile = Join-Path $target 'launch.ps1'
$config = [ordered]@{
    domesticInterface = $DomesticInterface; overseasInterface = $OverseasInterface
    pipeName = $PipeName; intervalSeconds = $IntervalSeconds; recoverySamples = $RecoverySamples
    stateFile = (Join-Path $target 'fallback-state.json'); logFile = (Join-Path $target 'fallback.log'); stopFile = $stopFile
}
$powerShellPath = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$ownedStartupValue = '"' + $powerShellPath + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcherFile + '"'
$manifest = $null
if ($Install) {
    $current = Read-Startup
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($manifest.version -ne 1 -or $manifest.stateDirectory -ne $state) { throw 'The installation manifest version or directory differs from this installation.' }
        if ($manifest.installed -and ($current.exists -ne $true -or $current.value -ne $manifest.ownedStartupValue)) { throw 'The login startup value changed externally. Restore or uninstall this installation before replacing it.' }
        if (-not $manifest.installed) { $manifest = $null }
    }
    if ($null -eq $manifest) {
        $manifest = [pscustomobject][ordered]@{
            version = 1; stateDirectory = $state; installed = $false
            originalStartupExists = $current.exists; originalStartupValue = $current.value
            ownedStartupValue = $ownedStartupValue; nodePath = $nodePath
            watcherFile = $watcherFile; configFile = $configFile; stopFile = $stopFile; intervalSeconds = $IntervalSeconds
        }
    }
}
$action = if ($Install) { 'Install auto fallback, register login startup and start the hidden watcher' } else { 'Generate auto fallback preview files' }
if (-not $PSCmdlet.ShouldProcess($target, $action)) { return }
if ($Install -and $manifest.installed) { Request-WatcherStop $manifest }
New-Item -ItemType Directory -Path $target -Force | Out-Null
if ($Install -and (Test-Path -LiteralPath $configFile -PathType Leaf)) {
    $backup = Join-Path $state ('backup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup | Out-Null
    foreach ($file in @($configFile, $watcherFile, $launcherFile, $manifestPath)) {
        if (Test-Path -LiteralPath $file -PathType Leaf) { Copy-Item -LiteralPath $file -Destination $backup }
    }
}
Save-Json $configFile $config
Copy-Item -LiteralPath $source -Destination $watcherFile -Force
# Embed only single-quoted PowerShell literals; apostrophes in filesystem paths
# are escaped. Node's Windows argument quoting is explicit at the process boundary.
$nodeLiteral = $nodePath.Replace("'", "''")
$argsLiteral = ('"' + $watcherFile + '" --config "' + $configFile + '"').Replace("'", "''")
$stopLiteral = $stopFile.Replace("'", "''")
$stderrLiteral = (Join-Path $target 'watcher-stderr.log').Replace("'", "''")
$supervisorLogLiteral = (Join-Path $target 'supervisor.log').Replace("'", "''")
$configIdentity = $configFile.ToUpperInvariant()
$sha = [Security.Cryptography.SHA256]::Create()
try { $mutexKey = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($configIdentity)))).Replace('-', '') }
finally { $sha.Dispose() }
$launcher = @"
`$ErrorActionPreference = 'Stop'
`$nodePath = '$nodeLiteral'
`$stopFile = '$stopLiteral'
`$stderrFile = '$stderrLiteral'
`$supervisorLog = '$supervisorLogLiteral'
function Write-SupervisorEvent(`$eventRecord) {
    try {
        if ((Test-Path -LiteralPath `$supervisorLog) -and (Get-Item -LiteralPath `$supervisorLog).Length -gt 262144) {
            [IO.File]::Copy(`$supervisorLog, `$supervisorLog + '.last', `$true)
            [IO.File]::WriteAllText(`$supervisorLog, '')
        }
        [IO.File]::AppendAllText(`$supervisorLog, ((`$eventRecord | ConvertTo-Json -Compress) + [Environment]::NewLine))
    } catch { }
}
`$mutex = New-Object Threading.Mutex(`$false, 'Local\ClashDualNicSupervisor-$mutexKey')
`$owned = `$false
try {
    try { `$owned = `$mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { `$owned = `$true }
    if (-not `$owned) { return }
    while (-not (Test-Path -LiteralPath `$stopFile)) {
        try {
            if ((Test-Path -LiteralPath `$stderrFile) -and (Get-Item -LiteralPath `$stderrFile).Length -gt 262144) {
                [IO.File]::Copy(`$stderrFile, `$stderrFile + '.last', `$true)
                [IO.File]::WriteAllText(`$stderrFile, '')
            }
            `$child = Start-Process -FilePath `$nodePath -WindowStyle Hidden -ArgumentList '$argsLiteral' -RedirectStandardError `$stderrFile -Wait -PassThru
            Write-SupervisorEvent ([ordered]@{ occurredAt = [DateTime]::UtcNow.ToString('o'); event = 'child-exited'; childPid = `$child.Id; exitCode = `$child.ExitCode })
        } catch {
            Write-SupervisorEvent ([ordered]@{ occurredAt = [DateTime]::UtcNow.ToString('o'); event = 'start-failed'; errorType = `$_.Exception.GetType().FullName })
            try { [IO.File]::AppendAllText(`$stderrFile, ([DateTime]::UtcNow.ToString('o') + ' ' + `$_.Exception.Message + [Environment]::NewLine)) } catch { }
        }
        # Poll the cooperative stop sentinel throughout the restart delay.
        for (`$retry = 0; `$retry -lt 10 -and -not (Test-Path -LiteralPath `$stopFile); `$retry++) {
            Start-Sleep -Milliseconds 500
        }
    }
} finally {
    if (`$owned) { `$mutex.ReleaseMutex() }
    `$mutex.Dispose()
}
"@
[IO.File]::WriteAllText($launcherFile, $launcher, (New-Object Text.UTF8Encoding($true)))
if (-not $Install) { Write-Output "Generated preview: $configFile"; return }
$manifest.ownedStartupValue = $ownedStartupValue
$manifest.nodePath = $nodePath
$manifest.intervalSeconds = $IntervalSeconds
$manifest.installed = $true
Save-Json $manifestPath $manifest
if (Test-Path -LiteralPath $stopFile) { Remove-Item -LiteralPath $stopFile }
if (-not (Test-Path -LiteralPath $registryPath)) { New-Item -Path $registryPath | Out-Null }
New-ItemProperty -LiteralPath $registryPath -Name $registryName -Value $ownedStartupValue -PropertyType String -Force | Out-Null
Start-Process -FilePath $powerShellPath -WindowStyle Hidden -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcherFile + '"')
Write-Output "Auto fallback installed and started. Config: $configFile"
Write-Output "Restore command: & '$($PSCommandPath.Replace("'", "''"))' -Uninstall -StateDirectory '$($state.Replace("'", "''"))'"
