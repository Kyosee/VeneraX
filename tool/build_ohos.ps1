param(
    [Parameter(Mandatory = $true)][string]$FlutterSdk,
    [Parameter(Mandatory = $true)][string]$DevEcoStudio,
    [ValidateSet('ohos-x64', 'ohos-arm64')][string]$TargetPlatform = 'ohos-x64',
    [string]$Target = 'lib/main.dart',
    [ValidateSet('debug', 'profile', 'release')][string]$BuildMode = 'debug',
    [switch]$CodeSign,
    [string]$OnnxSource,
    [string]$EigenSource,
    [string]$WebViewSource
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$flutter = Join-Path $FlutterSdk 'bin/flutter.bat'
$environmentNames = @(
    'OS', 'DEVECO_SDK_HOME', 'JAVA_HOME', 'NODE_HOME', 'Path',
    'FLUTTER_NATIVE_ASSETS', 'FLUTTER_DART_DATA_ASSETS'
)
$previousEnvironment = @{}
foreach ($name in $environmentNames) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

Push-Location $projectRoot
try {
    $env:OS = 'Windows_NT'
    $env:DEVECO_SDK_HOME = Join-Path $DevEcoStudio 'sdk'
    $env:JAVA_HOME = Join-Path $DevEcoStudio 'jbr'
    $env:NODE_HOME = Join-Path $DevEcoStudio 'tools/node'
    $env:Path = @(
        (Join-Path $FlutterSdk 'bin'), $env:NODE_HOME,
        (Join-Path $DevEcoStudio 'tools/ohpm/bin'),
        (Join-Path $DevEcoStudio 'tools/hvigor/bin'), $env:Path
    ) -join [IO.Path]::PathSeparator
    # OHOS native code is built by CMake. Upstream Dart hooks target Linux.
    $env:FLUTTER_NATIVE_ASSETS = 'false'
    $env:FLUTTER_DART_DATA_ASSETS = 'true'

    & $flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed.' }
    $prepareArguments = @('tool/prepare_ohos.dart')
    if ($WebViewSource) { $prepareArguments += $WebViewSource }
    & (Join-Path $FlutterSdk 'bin/dart.bat') @prepareArguments
    if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS dependency preparation failed.' }
    $sdkPackages = Join-Path $FlutterSdk 'packages/flutter_tools/.dart_tool/package_config.json'
    & (Join-Path $FlutterSdk 'bin/dart.bat') "--packages=$sdkPackages" .dart_tool/ohos/refresh_plugins.dart $FlutterSdk
    if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS plugin registration failed.' }
    & (Join-Path $PSScriptRoot 'build_ohos_rhttp.ps1') -NativeSdk (Join-Path $DevEcoStudio 'sdk/default/openharmony/native')
    & (Join-Path $PSScriptRoot 'build_ohos_onnx.ps1') -NativeSdk (Join-Path $DevEcoStudio 'sdk/default/openharmony/native') -SourceRoot $OnnxSource -EigenRoot $EigenSource
    $buildArguments = @('build', 'hap', "--$BuildMode", '--target-platform', $TargetPlatform, '--no-pub', '-t', $Target)
    if (-not $CodeSign) { $buildArguments += '--no-codesign' }
    & $flutter @buildArguments
    if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS HAP build failed.' }
} finally {
    foreach ($name in $environmentNames) {
        if ($null -eq $previousEnvironment[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    }
    Pop-Location
}
