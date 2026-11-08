param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$NativeSdk,
    [ValidateNotNullOrEmpty()][string]$Toolchain = '1.85.1',
    [ValidateRange(1, 8)][int]$Jobs = 8
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$packageConfigPath = Join-Path $projectRoot '.dart_tool/package_config.json'
if (-not (Test-Path -LiteralPath $packageConfigPath -PathType Leaf)) {
    throw "Package configuration is missing: $packageConfigPath. Run Flutter pub get first."
}
$packageConfig = Get-Content -LiteralPath $packageConfigPath -Raw | ConvertFrom-Json
$rhttpPackages = @($packageConfig.packages | Where-Object { $_.name -eq 'rhttp' })
if ($rhttpPackages.Count -ne 1 -or [string]::IsNullOrWhiteSpace($rhttpPackages[0].rootUri)) {
    throw "Package configuration must contain one rhttp package with a rootUri: $packageConfigPath"
}
$packageConfigUri = [Uri]::new(([Uri]$packageConfigPath).AbsoluteUri)
$packageUri = [Uri]::new($packageConfigUri, [string]$rhttpPackages[0].rootUri)
if (-not $packageUri.IsFile) {
    throw "rhttp rootUri must resolve to a local file URI: $($rhttpPackages[0].rootUri)"
}
$manifestPath = Join-Path $packageUri.LocalPath 'rust/Cargo.toml'
$lockPath = Join-Path $packageUri.LocalPath 'rust/Cargo.lock'
foreach ($path in @($manifestPath, $lockPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required rhttp source file is missing: $path"
    }
}

$NativeSdk = (Resolve-Path -LiteralPath $NativeSdk).Path
foreach ($relativePath in @('llvm/bin/clang.exe', 'llvm/bin/llvm-ar.exe', 'llvm/bin/ld.lld.exe', 'sysroot')) {
    $path = Join-Path $NativeSdk $relativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required OHOS native SDK component is missing: $path"
    }
}
$clangWrapper = Join-Path $PSScriptRoot 'clang_ohos.cmd'
if (-not (Test-Path -LiteralPath $clangWrapper -PathType Leaf)) {
    throw "OHOS clang wrapper is missing: $clangWrapper"
}

& rustup run $Toolchain rustc --version
if ($LASTEXITCODE -ne 0) {
    throw "Rust toolchain '$Toolchain' must already be installed and usable."
}
$targets = [ordered]@{
    'x86_64-unknown-linux-ohos' = 'x86_64'
    'aarch64-unknown-linux-ohos' = 'arm64-v8a'
}
$installedTargets = & rustup target list --installed --toolchain $Toolchain
if ($LASTEXITCODE -ne 0) { throw "Cannot inspect Rust targets for toolchain '$Toolchain'." }
$missingTargets = @($targets.Keys | Where-Object { $_ -notin $installedTargets })
if ($missingTargets.Count -gt 0) {
    throw "Missing OHOS Rust targets: $($missingTargets -join ', '). Run: rustup target add x86_64-unknown-linux-ohos aarch64-unknown-linux-ohos --toolchain $Toolchain"
}

# Keep the validated probe directory for local proc-macro build tools.
$targetDir = Join-Path $projectRoot "build/rhttp_ohos_probe/$Toolchain"
$environment = @{
    RHTTP_OHOS_NATIVE = $NativeSdk
    RHTTP_OHOS_CLANG_TARGET = 'x86_64-linux-ohos'
    CARGO_ENCODED_RUSTFLAGS = "--cfg$([char]31)reqwest_unstable"
}
foreach ($target in $targets.Keys) {
    $ccTarget = $target.Replace('-', '_')
    $cargoTarget = $ccTarget.ToUpperInvariant()
    $environment["CARGO_TARGET_${cargoTarget}_LINKER"] = $clangWrapper
    $environment["CC_$ccTarget"] = $clangWrapper
    $environment["AR_$ccTarget"] = Join-Path $NativeSdk 'llvm/bin/llvm-ar.exe'
}
$previousEnvironment = @{}
foreach ($name in $environment.Keys) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

Push-Location $projectRoot
try {
    foreach ($name in $environment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process')
    }
    $libraries = [ordered]@{}
    foreach ($target in $targets.Keys) {
        [Environment]::SetEnvironmentVariable('RHTTP_OHOS_CLANG_TARGET', $target.Replace('-unknown', ''), 'Process')
        Write-Host "Building rhttp for $target..."
        & cargo "+$Toolchain" build --locked --release --lib --jobs $Jobs --manifest-path $manifestPath --target $target --target-dir $targetDir
        if ($LASTEXITCODE -ne 0) { throw "rhttp build failed for $target." }
        $library = Join-Path $targetDir "$target/release/librhttp.so"
        if (-not (Test-Path -LiteralPath $library -PathType Leaf)) {
            throw "Built rhttp library is missing: $library"
        }
        $libraries[$targets[$target]] = $library
    }
    foreach ($abi in $libraries.Keys) {
        $destinationDirectory = Join-Path $projectRoot "ohos/entry/libs/$abi"
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        $destination = Join-Path $destinationDirectory 'librhttp.so'
        Copy-Item -LiteralPath $libraries[$abi] -Destination $destination -Force
        Write-Host "Copied rhttp to $destination"
    }
} finally {
    foreach ($name in $environment.Keys) {
        if ($null -eq $previousEnvironment[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    }
    Pop-Location
}
