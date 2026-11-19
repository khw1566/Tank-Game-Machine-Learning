$ErrorActionPreference = 'Stop'
$workspacePath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$syncPath = (Resolve-Path -LiteralPath (Join-Path $workspacePath '_sync')).Path
$plan = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'safe-cleanup-plan-20261119.json') -Raw | ConvertFrom-Json
$processes = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($syncPath + '\', [StringComparison]::OrdinalIgnoreCase) })
if ($processes.Count -gt 0) { throw 'A staging executable is still running; cleanup cancelled.' }
foreach ($entry in $plan.entries) {
    $resolvedPath = [IO.Path]::GetFullPath($entry.path)
    if (-not $resolvedPath.StartsWith($syncPath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup target outside staging area.' }
    $file = [IO.FileInfo]::new($resolvedPath)
    if (-not $file.Exists -or $file.Length -ne $entry.bytes -or $file.Extension -eq '.csv') { throw 'Cleanup target changed or is protected.' }
}
foreach ($retained in ($plan.entries.retained | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $retained -PathType Leaf)) { throw 'Retained original is missing.' }
}
$deleted = 0
$freed = [long]0
foreach ($entry in $plan.entries) {
    Remove-Item -LiteralPath $entry.path -Force
    $deleted++
    $freed += $entry.bytes
    if ($deleted % 10000 -eq 0) { Write-Output "Removed $deleted verified staging files" }
}
[pscustomobject]@{DeletedFiles=$deleted;FreedBytes=$freed} | ConvertTo-Json
