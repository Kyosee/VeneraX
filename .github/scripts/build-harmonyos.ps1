param(
    [Parameter(Mandatory = $true)][string]$Checkout,
    [Parameter(Mandatory = $true)][string]$SourceRepository,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$Commit,
    [Parameter(Mandatory = $true)][string]$FlutterSdk,
    [Parameter(Mandatory = $true)][string]$DevEcoStudio,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [switch]$UsePreparedNativeLibraries
)

$ErrorActionPreference = 'Stop'
$flutterCommand = if ($env:OS -eq 'Windows_NT') { 'bin/flutter.bat' } else { 'bin/flutter' }
$checkoutRoot = (Resolve-Path -LiteralPath $Checkout).Path
$sourceRoot = (Resolve-Path -LiteralPath $SourceRepository).Path
if ($checkoutRoot -eq $sourceRoot) {
    throw 'HarmonyOS requires a separate checkout from the standard Flutter build.'
}
foreach ($path in @(
    (Join-Path $checkoutRoot '.git'),
    (Join-Path $FlutterSdk $flutterCommand),
    (Join-Path $DevEcoStudio 'sdk/default/openharmony')
)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing build prerequisite: $path" }
}

# Preserve local source changes and generated native libraries in the OH checkout.
$changes = & git -C $checkoutRoot status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the HarmonyOS checkout.' }
if ($changes) { throw 'The HarmonyOS checkout has tracked changes; refusing to overwrite them.' }
& git -C $checkoutRoot fetch --no-tags $sourceRoot $Commit
if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch the requested build commit.' }
& git -C $checkoutRoot merge --ff-only --no-edit $Commit
if ($LASTEXITCODE -ne 0) { throw 'The HarmonyOS checkout cannot fast-forward to the requested commit.' }
$actualCommit = & git -C $checkoutRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $Commit) {
    throw 'The HarmonyOS checkout does not match the requested build commit.'
}

$versionLine = Select-String -LiteralPath (Join-Path $checkoutRoot 'pubspec.yaml') -Pattern '^version:\s*(\S+)\s*$'
if ($versionLine.Count -ne 1) { throw 'Expected one application version in pubspec.yaml.' }
$appVersion = $versionLine.Matches[0].Groups[1].Value
if ($appVersion -notmatch '^([^+]+)\+(\d+)$') { throw "Invalid application version: $appVersion" }
$versionName = $Matches[1]
$versionCode = [int]$Matches[2]
# Match Flutter OH's validatedBuildNameForPlatform for native versionName.
$ohosVersionParts = @(($versionName -replace '[^\d.]', '') -split '\.' | Where-Object { $_ -ne '' })
while ($ohosVersionParts.Count -lt 3) { $ohosVersionParts += '0' }
$ohosVersionName = $ohosVersionParts -join '.'

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
if (Get-ChildItem -LiteralPath $OutputDirectory -Filter '*.hap') {
    throw 'The output directory already contains HAP files; use an empty directory.'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$nativeLibraries = @(
    'libapp.so', 'libflutter.so', 'libc++_shared.so', 'libflutter_7zip.so',
    # PDF rendering is provided by HarmonyOS PDF Kit.
    'liblodepng_flutter.so', 'libonnxruntime.so', 'libinappwebview.so',
    'libqjs.so', 'librhttp.so', 'libsqlite3.so', 'libzip_flutter.so'
)
$buildScript = Join-Path $checkoutRoot 'tool/build_ohos.ps1'
$builtHap = Join-Path $checkoutRoot 'build/ohos/hap/entry-default-unsigned.hap'
if (Test-Path -LiteralPath $builtHap) { Remove-Item -LiteralPath $builtHap -Force }
& $buildScript -FlutterSdk $FlutterSdk -DevEcoStudio $DevEcoStudio `
    -Target lib/main.dart -TargetPlatform 'ohos-arm64' -BuildMode release `
    -UsePreparedNativeLibraries:$UsePreparedNativeLibraries
if ($LASTEXITCODE -ne 0) { throw "HarmonyOS build failed for ohos-arm64." }
if (-not (Test-Path -LiteralPath $builtHap) -or (Get-Item -LiteralPath $builtHap).Length -eq 0) {
    throw "Missing HarmonyOS package for ohos-arm64."
}

$archive = [IO.Compression.ZipFile]::OpenRead($builtHap)
try {
    $manifestEntry = $archive.GetEntry('module.json')
    if ($null -eq $manifestEntry) { throw 'The HAP has no module.json.' }
    $reader = [IO.StreamReader]::new($manifestEntry.Open())
    try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    $app = $manifest.app
    if ($app.versionName -ne $ohosVersionName -or $app.versionCode -ne $versionCode) {
        throw "Packaged version does not match $appVersion (expected $ohosVersionName/$versionCode)."
    }
    if ($app.bundleName -ne 'com.github.kyosee.venera' -or
        $app.debug -ne $false -or $app.buildMode -ne 'release') {
        throw 'Expected the VeneraX release application in the HAP.'
    }
    $abis = @($archive.Entries.FullName | ForEach-Object {
        if ($_ -match '^libs/([^/]+)/[^/]+\.so$') { $Matches[1] }
    } | Sort-Object -Unique)
    if ($abis.Count -ne 1 -or $abis[0] -ne 'arm64-v8a') {
        throw "Unexpected packaged ABI: $($abis -join ', '); expected arm64-v8a."
    }
    foreach ($library in $nativeLibraries) {
        $entry = $archive.GetEntry("libs/arm64-v8a/$library")
        if ($null -eq $entry -or $entry.Length -eq 0) {
            throw "Missing native library: $library (arm64-v8a)."
        }
    }
} finally {
    $archive.Dispose()
}
$filename = "VeneraX-$appVersion-harmonyos-unsigned.hap"
Copy-Item -LiteralPath $builtHap -Destination (Join-Path $OutputDirectory $filename)
Write-Host "Verified $filename (release, arm64-v8a)."
