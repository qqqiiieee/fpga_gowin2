param([string]$ToolchainRoot = '')
$ErrorActionPreference = 'Stop'
$bridgeRoot = $PSScriptRoot
$bridgeExternal = -not [string]::IsNullOrWhiteSpace($ToolchainRoot)
$bridgeTc = if ($bridgeExternal) { (Resolve-Path -LiteralPath $ToolchainRoot).Path } else { Join-Path $bridgeRoot '.toolchain' }
$bridgeWork = Join-Path $bridgeRoot '.build_work'
$bridgeCli = Join-Path $bridgeTc 'cli\arduino-cli.exe'
if (-not (Test-Path -LiteralPath (Join-Path $bridgeTc 'manifest.json'))) {
    if ($bridgeExternal) { throw 'Existing toolchain incomplete; refusing download or baseline modification.' }
    & python (Join-Path $bridgeRoot 'bootstrap_toolchain.py')
    if ($LASTEXITCODE -ne 0) { throw 'Isolated toolchain bootstrap failed.' }
}
$bridgeOldTemp = $env:TEMP
$bridgeOldTmp = $env:TMP
try {
    $env:TEMP = Join-Path $bridgeWork 'temp'
    $env:TMP = $env:TEMP
    New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $bridgeRoot 'build') | Out-Null
    # CLI scans sketch headers recursively, including hidden .toolchain folders.
    # Stage only the three authoritative source files to avoid huge include lists.
    $bridgeStage = Join-Path $bridgeWork 'sketch\esp32_phone'
    New-Item -ItemType Directory -Force -Path $bridgeStage | Out-Null
    foreach ($bridgeFile in @('esp32_phone.ino', 'bridge_core.h', 'web_ui.h')) {
        Copy-Item -LiteralPath (Join-Path $bridgeRoot $bridgeFile) -Destination $bridgeStage -Force
    }
    # Core 2.x's SDK include list exceeds CreateProcess's 32767-character limit
    # in long workspace paths. A local junction shortens only these build paths.
    $bridgeSdk = Join-Path $bridgeTc 'sdk'
    $bridgeSdkTarget = Join-Path $bridgeTc 'data\packages\esp32\hardware\esp32\2.0.17\tools\sdk\esp32'
    if (-not (Test-Path -LiteralPath $bridgeSdk)) {
        if ($bridgeExternal) { throw 'Existing SDK shortcut missing; refusing baseline modification.' }
        New-Item -ItemType Junction -Path $bridgeSdk -Target $bridgeSdkTarget | Out-Null
    }
    $bridgeGcc = Join-Path $bridgeTc 'gcc'
    $bridgeGccTarget = Join-Path $bridgeTc 'data\packages\esp32\tools\xtensa-esp32-elf-gcc\esp-2021r2-patch5-8.4.0'
    if (-not (Test-Path -LiteralPath $bridgeGcc)) {
        if ($bridgeExternal) { throw 'Existing compiler shortcut missing; refusing baseline modification.' }
        New-Item -ItemType Junction -Path $bridgeGcc -Target $bridgeGccTarget | Out-Null
    }
    # Reuse installed packages/compiler only; stage, core cache and outputs are V031-owned.
    $bridgeConfig = Join-Path $bridgeWork 'arduino-cli.yaml'
    [ordered]@{
        directories = @{ data = (Join-Path $bridgeTc 'data'); downloads = (Join-Path $bridgeWork 'downloads'); user = (Join-Path $bridgeWork 'sketchbook') }
        build_cache = @{ path = (Join-Path $bridgeWork 'cache') }
        metrics = @{ enabled = $false }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $bridgeConfig -Encoding utf8
    & $bridgeCli compile --config-file $bridgeConfig `
        --fqbn 'esp32:esp32:esp32' --warnings all `
        --jobs 2 `
        --build-property "compiler.sdk.path=$bridgeSdk" `
        --build-property "compiler.path=$bridgeGcc/bin/" `
        --build-path (Join-Path $bridgeWork 'compile') `
        --output-dir (Join-Path $bridgeRoot 'build') $bridgeStage 2>&1 |
        Tee-Object -FilePath (Join-Path $bridgeRoot 'build\compile.log')
    $bridgeCompileExit = $LASTEXITCODE
    $bridgeHashes = @{}
    foreach ($bridgeFile in @('esp32_phone.ino', 'bridge_core.h', 'web_ui.h')) {
        $bridgeHashes[$bridgeFile] = (Get-FileHash -LiteralPath (Join-Path $bridgeStage $bridgeFile) -Algorithm SHA256).Hash
    }
    $bridgeBinaryHashes = @{}
    if ($bridgeCompileExit -eq 0) {
        Get-ChildItem -LiteralPath (Join-Path $bridgeRoot 'build') -File -Filter '*.bin' | ForEach-Object {
            $bridgeBinaryHashes[$_.Name] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    }
    [ordered]@{
        time_beijing = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTimeOffset]::UtcNow, 'China Standard Time').ToString('o')
        compile_passed = ($bridgeCompileExit -eq 0)
        exit_code = $bridgeCompileExit
        fqbn = 'esp32:esp32:esp32'
        core = '2.0.17'
        toolchain_root = $bridgeTc
        build_work = $bridgeWork
        reused_existing_toolchain = $bridgeExternal
        source_sha256 = $bridgeHashes
        binary_sha256 = $bridgeBinaryHashes
        uploaded = $false
        hardware_validated = $false
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $bridgeRoot 'build\build-result.json') -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $bridgeTc 'manifest.json') -Destination (Join-Path $bridgeRoot 'build\toolchain-manifest.json') -Force
    if ($bridgeCompileExit -ne 0) { throw "Compile failed: $bridgeCompileExit" }
} finally {
    $env:TEMP = $bridgeOldTemp
    $env:TMP = $bridgeOldTmp
}
