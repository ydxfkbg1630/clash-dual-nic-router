$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$install = Join-Path $repo 'scripts\Install-Routing.ps1'
$restore = Join-Path $repo 'scripts\Restore-Routing.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('dual-nic-test-' + [guid]::NewGuid().ToString('N'))
$config = Join-Path $root '配置目录'
$state = Join-Path $root 'state'
New-Item -ItemType Directory -Path (Join-Path $config 'profiles') -Force | Out-Null
# Mock only adapter enumeration; all file operations use real temporary files.
function Get-NetAdapter {
    [pscustomobject]@{Name='Test Ethernet';Status='Up'}
    [pscustomobject]@{Name='Test Wi-Fi';Status='Up'}
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
$target = Join-Path $config 'profiles\Script.js'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$original = "// user extension`nfunction main(config) { config.example = true; return config; }"
[IO.File]::WriteAllText($target,$original,$utf8)
$hash = (Get-FileHash $target).Hash
& $install -DomesticInterface 'Test Ethernet' -OverseasInterface 'Test Wi-Fi' -ConfigDirectory $config -StateDirectory $state | Out-Null
Assert ((Get-FileHash $target).Hash -eq $hash) 'Generate-only changed the active file.'
$blocked = $false
try { & $install -DomesticInterface 'Test Ethernet' -OverseasInterface 'Test Wi-Fi' -ConfigDirectory $config -StateDirectory $state -Install | Out-Null } catch { $blocked=$true }
Assert $blocked 'Custom-script guard failed.'
& $install -DomesticInterface 'Test Ethernet' -OverseasInterface 'Test Wi-Fi' -PreferredProxy 'Node $1 "quoted"' -ConfigDirectory $config -StateDirectory $state -Install -ReplaceExisting | Out-Null
$manifest = Get-ChildItem -LiteralPath $state -Filter manifest.json -Recurse | Select-Object -First 1
Assert ($null -ne $manifest) 'Missing backup manifest.'
$backup = $manifest.DirectoryName
Assert ([IO.File]::ReadAllText((Join-Path $backup 'original.js')) -eq $original) 'Original backup differs.'
& node --check $target
Assert ($LASTEXITCODE -eq 0) 'Generated script syntax failed.'
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
Write-Output 'PASS: generation, custom-script guard, install, escaping, backup, changed-file guard, restore, edit preservation, distinct adapters.'
Write-Output "Temporary test files: $root"
