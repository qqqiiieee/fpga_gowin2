param([string]$Python = 'python')
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    New-Item -ItemType Directory -Force -Path 'build' | Out-Null
    & $Python (Join-Path $PSScriptRoot 'run_native.py') 2>&1 | Tee-Object -FilePath 'build/native-test.log'
    if ($LASTEXITCODE -ne 0) { throw 'Native bridge tests failed.' }
    & node (Join-Path $PSScriptRoot 'web_ui.test.cjs') 2>&1 | Tee-Object -FilePath 'build/web-test.log'
    if ($LASTEXITCODE -ne 0) { throw 'Offline UI tests failed.' }
} finally {
    Pop-Location
}
