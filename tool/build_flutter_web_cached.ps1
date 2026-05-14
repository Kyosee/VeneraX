param(
  [string]$BaseHref = "/",
  [switch]$Force
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$webBuildPath = Join-Path $root "build/web"
$stampPath = Join-Path $webBuildPath ".venera-build-stamp.json"
$inputPaths = @(
  (Join-Path $root "pubspec.yaml"),
  (Join-Path $root "pubspec.lock"),
  (Join-Path $root "lib"),
  (Join-Path $root "assets"),
  (Join-Path $root "web/index.html"),
  (Join-Path $root "web/manifest.json"),
  (Join-Path $root "web/flutter_bootstrap.js"),
  (Join-Path $root "web/flutter.js"),
  (Join-Path $root "web/icons"),
  (Join-Path $root "web/favicon.png"),
  (Join-Path $root "web/apple-touch-icon.png"),
  (Join-Path $root "web/venera_runtime.js"),
  (Join-Path $root "web/sqlite3.wasm"),
  (Join-Path $root "web/proxy.php")
)

function Get-InputFiles {
  $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
  foreach ($path in $inputPaths) {
    if (-not (Test-Path -LiteralPath $path)) {
      continue
    }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.PSIsContainer) {
      foreach ($file in Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue) {
        $files.Add($file)
      }
    } else {
      $files.Add($item)
    }
  }
  return $files | Sort-Object FullName
}

function Get-RelativePath {
  param([System.IO.FileInfo]$File)

  $rootFullPath = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
  $fileFullPath = [System.IO.Path]::GetFullPath($File.FullName)
  return $fileFullPath.Substring($rootFullPath.Length).Replace('\', '/')
}

function Get-Fingerprint {
  $builder = [System.Text.StringBuilder]::new()
  [void]$builder.AppendLine("target=lib/main_web.dart")
  [void]$builder.AppendLine("baseHref=$BaseHref")
  foreach ($file in (Get-InputFiles)) {
    [void]$builder.AppendLine("$(Get-RelativePath $file)|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)")
  }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($builder.ToString())
    return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-LatestInputWriteTimeUtc {
  $latest = [DateTime]::MinValue
  foreach ($file in (Get-InputFiles)) {
    if ($file.LastWriteTimeUtc -gt $latest) {
      $latest = $file.LastWriteTimeUtc
    }
  }
  return $latest
}

function Write-Stamp {
  param([string]$Fingerprint)

  if (-not (Test-Path -LiteralPath $webBuildPath)) {
    New-Item -ItemType Directory -Path $webBuildPath | Out-Null
  }
  @{
    version = 1
    baseHref = $BaseHref
    target = "lib/main_web.dart"
    fingerprint = $Fingerprint
    builtAt = (Get-Date).ToUniversalTime().ToString("o")
  } | ConvertTo-Json | Set-Content -LiteralPath $stampPath -Encoding UTF8
}

function Test-BuildFresh {
  param([string]$Fingerprint)

  $mainJsPath = Join-Path $webBuildPath "main.dart.js"
  $indexPath = Join-Path $webBuildPath "index.html"
  if (-not (Test-Path -LiteralPath $mainJsPath) -or -not (Test-Path -LiteralPath $indexPath)) {
    return $false
  }
  if (Test-Path -LiteralPath $stampPath) {
    try {
      $stamp = Get-Content -LiteralPath $stampPath -Raw | ConvertFrom-Json
      if ($stamp.baseHref -eq $BaseHref -and
          $stamp.target -eq "lib/main_web.dart" -and
          $stamp.fingerprint -eq $Fingerprint) {
        return $true
      }
      Write-Host "Build stamp is stale; checking file timestamps."
    } catch {
      Write-Host "Build stamp is invalid; checking file timestamps."
    }
  }
  $outputTime = (Get-Item -LiteralPath $mainJsPath).LastWriteTimeUtc
  if ($outputTime -ge (Get-LatestInputWriteTimeUtc)) {
    Write-Stamp $Fingerprint
    return $true
  }
  return $false
}

Push-Location $root
try {
  $fingerprint = Get-Fingerprint
  if (-not $Force -and (Test-BuildFresh $fingerprint)) {
    Write-Host "Reusing fresh build/web. Use -Force to rebuild."
    return
  }
  flutter build web --target lib/main_web.dart --release --base-href $BaseHref --no-wasm-dry-run --no-tree-shake-icons
  if ($LASTEXITCODE -ne 0) {
    throw "flutter build web failed with exit code $LASTEXITCODE"
  }
  Write-Stamp $fingerprint
} finally {
  Pop-Location
}
