[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$BackupDirectory, [switch]$Force)
$ErrorActionPreference = 'Stop'
$backup = [IO.Path]::GetFullPath($BackupDirectory)
$manifest = [IO.File]::ReadAllText((Join-Path $backup 'manifest.json')) | ConvertFrom-Json
if ($manifest.version -ne 1) { throw 'Use a version 1 backup manifest.' }
$target = [IO.Path]::GetFullPath($manifest.target)
if ([IO.Path]::GetFileName($target) -ne 'Script.js') { throw 'Expected a Script.js target.' }
if (Test-Path -LiteralPath $target) {
    $currentHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($currentHash -ne $manifest.installedSha256 -and -not $Force) { throw 'The script has changed since installation. Review those edits, then use -Force to restore.' }
    $saved = Join-Path $backup ('before-restore-' + [guid]::NewGuid().ToString('N') + '.js')
    Copy-Item -LiteralPath $target -Destination $saved
}
if ($manifest.hadOriginal) {
    Copy-Item -LiteralPath (Join-Path $backup 'original.js') -Destination $target -Force
} else {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($target,"function main(config) { return config; }`n",$utf8)
}
Write-Output "Restored: $target"
Write-Output 'Save the global extension script in Clash Verge to reload; set Rule/TUN controls to your previous preferences.'
