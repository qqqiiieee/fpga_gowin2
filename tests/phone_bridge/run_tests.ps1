$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    New-Item -ItemType Directory -Force -Path 'build' | Out-Null
    & '.\run_native.cmd' 2>&1 | Tee-Object -FilePath 'build\native-test.log'
    if ($LASTEXITCODE -ne 0) { throw 'Native bridge tests failed.' }
    & node '.\web_ui.test.cjs' 2>&1 | Tee-Object -FilePath 'build\web-test.log'
    if ($LASTEXITCODE -ne 0) { throw 'Offline UI tests failed.' }
} finally {
    Pop-Location
}
