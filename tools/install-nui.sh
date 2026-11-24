#!/bin/sh
# Install the `nui` CLI for nanoui.
#
# By default, downloads the release archive for this OS/arch from GitHub,
# verifies its SHA-256 checksum, and installs `nui` into ~/.local/bin
# (or $NUI_INSTALL_DIR / --dir PATH).
#
# With `--from-source` (when inside a nanoui checkout), builds `zig build nui`
# with Zig 0.17 and installs `zig-out/bin/nui`.
set -eu

repo="${NUI_REPO:-justrach/nanoui}"
dir="${NUI_INSTALL_DIR:-$HOME/.local/bin}"
version="latest"
from_source=0

usage() {
    cat <<'EOF'
Usage: install-nui.sh [OPTIONS]

Options:
  --from-source       Build `nui` from this checkout with `zig build nui`
  --version TAG       Release tag to download (e.g. v0.14.9; default: latest)
  --dir PATH          Destination directory (default: $NUI_INSTALL_DIR or ~/.local/bin)
  -h, --help          Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --from-source) from_source=1; shift ;;
        --version)
            [ "$#" -ge 2 ] || { echo "install-nui.sh: --version needs a value" >&2; exit 2; }
            version="$2"; shift 2 ;;
        --dir)
            [ "$#" -ge 2 ] || { echo "install-nui.sh: --dir needs a value" >&2; exit 2; }
            dir="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "install-nui.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

sha256_check() {
    sums="$1"
    file="$2"
    expected="$(awk -v f="$file" '$2 == f || $2 == ("*" f) { print $1; exit }' "$sums")"
    [ -n "$expected" ] || { echo "install-nui.sh: no checksum entry for $file" >&2; exit 1; }
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$file" | awk '{print $1}')"
    else
        actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    fi
    [ "$actual" = "$expected" ] || {
        echo "install-nui.sh: checksum mismatch for $file (expected $expected, got $actual)" >&2
        exit 1
    }
}

mkdir -p "$dir"

if [ "$from_source" -eq 1 ]; then
    root="$(cd "$(dirname "$0")/.." && pwd)"
    command -v zig >/dev/null 2>&1 || { echo "install-nui.sh: zig 0.17 not found in PATH" >&2; exit 1; }
    zver="$(zig version)"
    case "$zver" in
        0.17.*) ;;
        *) echo "install-nui.sh: nanoui requires Zig 0.17 (found $zver)" >&2; exit 1 ;;
    esac
    (cd "$root" && zig build nui -Doptimize=ReleaseSafe)
    cp "$root/zig-out/bin/nui" "$dir/nui"
    chmod +x "$dir/nui"
else
    case "$(uname -s)" in
        Darwin) os="macos" ;;
        Linux) os="linux" ;;
        *) echo "install-nui.sh: unsupported OS $(uname -s) (use --from-source or download from GitHub Releases)" >&2; exit 1 ;;
    esac
    case "$(uname -m)" in
        arm64|aarch64) arch="aarch64" ;;
        x86_64|amd64) arch="x86_64" ;;
        *) echo "install-nui.sh: unsupported arch $(uname -m)" >&2; exit 1 ;;
    esac
    name="nui-$os-$arch"
    archive="$name.tar.gz"
    if [ "$version" = "latest" ]; then
        base="https://github.com/$repo/releases/latest/download"
    else
        base="https://github.com/$repo/releases/download/$version"
    fi
    work="$(mktemp -d "${TMPDIR:-/tmp}/nui-install.XXXXXXXX")"
    trap 'rm -rf "$work"' EXIT
    trap 'exit 1' HUP INT TERM

    echo "Downloading $archive from $base..."
    curl -fsSL "$base/$archive" -o "$work/$archive"
    curl -fsSL "$base/SHA256SUMS" -o "$work/SHA256SUMS"
    (cd "$work" && sha256_check SHA256SUMS "$archive")
    tar -C "$work" -xzf "$work/$archive"
    cp "$work/$name/nui" "$dir/nui"
    chmod +x "$dir/nui"
fi

echo "Installed nui to $dir/nui"
case ":$PATH:" in
    *":$dir:"*) ;;
    *) echo "Add $dir to your PATH: export PATH=\"$dir:\$PATH\"" ;;
esac
"$dir/nui" version
