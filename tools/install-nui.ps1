# Install the `nui` CLI for nanoui on Windows.
#
# By default, downloads the release archive for this architecture from GitHub,
# verifies its SHA-256 checksum, and installs `nui.exe` into %LOCALAPPDATA%\nanoui\bin
# (or -Dir PATH). With `-FromSource` (inside a nanoui checkout), builds `zig build nui`
# with Zig 0.17 and installs `zig-out\bin\nui.exe`.
[CmdletBinding()]
param(
    [switch]$FromSource,
    [string]$Version = "latest",
    [string]$Dir = $(if ($env:NUI_INSTALL_DIR) { $env:NUI_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "nanoui\bin" }),
    [string]$Repo = $(if ($env:NUI_REPO) { $env:NUI_REPO } else { "justrach/nanoui" })
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path $Dir | Out-Null

if ($FromSource) {
    $zig = Get-Command zig -ErrorAction SilentlyContinue
    if (-not $zig) { throw "install-nui.ps1: zig 0.17 not found in PATH" }
    $zver = (& zig version).Trim()
    if (-not $zver.StartsWith("0.17.")) {
        throw "install-nui.ps1: nanoui requires Zig 0.17 (found $zver)"
    }
    $root = Split-Path -Parent $PSScriptRoot
    Push-Location $root
    try {
        & zig build nui -Doptimize=ReleaseSafe
        if ($LASTEXITCODE -ne 0) { throw "zig build nui failed" }
    } finally {
        Pop-Location
    }
    Copy-Item (Join-Path $root "zig-out\bin\nui.exe") (Join-Path $Dir "nui.exe") -Force
} else {
    $archRaw = try {
        [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    } catch {
        $env:PROCESSOR_ARCHITECTURE
    }
    $arch = switch -Regex ($archRaw) {
        "^(X64|AMD64)$" { "x86_64" }
        "^Arm64$" { "aarch64" }
        default { throw "install-nui.ps1: unsupported architecture $archRaw (use -FromSource)" }
    }
    $name = "nui-windows-$arch"
    $archive = "$name.zip"
    $base = if ($Version -eq "latest") {
        "https://github.com/$Repo/releases/latest/download"
    } else {
        "https://github.com/$Repo/releases/download/$Version"
    }

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("nui-install-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $zipPath = Join-Path $work $archive
        $sumsPath = Join-Path $work "SHA256SUMS"
        Write-Host "Downloading $archive from $base..."
        Invoke-WebRequest -Uri "$base/$archive" -OutFile $zipPath
        Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile $sumsPath

        $expected = $null
        foreach ($line in Get-Content $sumsPath) {
            if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
                if ($Matches[2] -eq $archive) {
                    $expected = $Matches[1].ToLowerInvariant()
                    break
                }
            }
        }
        if (-not $expected) { throw "install-nui.ps1: no checksum entry for $archive" }
        $actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "install-nui.ps1: checksum mismatch for $archive (expected $expected, got $actual)"
        }

        Expand-Archive -Path $zipPath -DestinationPath $work -Force
        Copy-Item (Join-Path $work "$name\nui.exe") (Join-Path $Dir "nui.exe") -Force
    } finally {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work
    }
}

$exe = Join-Path $Dir "nui.exe"
Write-Host "Installed nui to $exe"
if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $Dir })) {
    Write-Host "Add $Dir to PATH: `$env:PATH = `"$Dir;`$env:PATH`""
}
& $exe version
if ($LASTEXITCODE -ne 0) { throw "installed nui failed to run" }
