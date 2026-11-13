#!/bin/sh
# The cheap CI checks, run on a Git tree in a temporary directory. No source
# files or index entries are changed; submodule working trees are not exported.
set -eu
if [ "$#" -ne 1 ]; then
    echo 'usage: sh tools/check-snapshot.sh --staged|TREE' >&2
    exit 2
fi
if [ "$1" = --staged ]; then
    tree=$(git write-tree)
else
    tree=$(git rev-parse --verify --end-of-options "$1^{tree}")
fi
if [ "$(zig version)" != 0.17.0 ]; then
    echo 'nanoui: these checks require Zig 0.17.0' >&2
    exit 1
fi
objects=$(git rev-parse --path-format=absolute --git-path objects)
object_format=$(git rev-parse --show-object-format)
work=$(mktemp -d "${TMPDIR:-/tmp}/nanoui-hooks.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$work/tree"
# Archive raw blobs without checkout/smudge/EOL conversion. A private Git
# directory supplies the highest-priority attributes, so export-ignore and
# export-subst cannot hide or rewrite files. Export settings stay temporary.
(
    export GIT_DIR="$work/export.git" GIT_COMMON_DIR="$work/export.git"
    export GIT_INDEX_FILE="$work/export-index"
    unset GIT_WORK_TREE GIT_OBJECT_DIRECTORY
    git -c init.templateDir= init --bare --object-format="$object_format" -q "$work/export.git"
    mkdir -p "$work/export.git/info"
    printf '* -export-ignore -export-subst\n' > "$work/export.git/info/attributes"
    GIT_OBJECT_DIRECTORY="$objects" git archive --format=tar --output="$work/tree.tar" "$tree"
)
tar -xf "$work/tree.tar" -C "$work/tree"
if ! (
    cd "$work/tree"
    # Capture diagnostics through a pipe before writing them to the hook's
    # stderr, which Git or a caller may redirect to a regular log file.
    if ! formatting=$(zig fmt --check src build.zig build.zig.zon examples tools 2>&1); then
        printf '%s\n' "$formatting" >&2
        exit 1
    fi
    # Run just the line checker: no build graph, SDKs or dependency fetching.
    zig run tools/lines.zig --cache-dir "$work/cache" || exit 1
); then
    echo 'nanoui: snapshot checks failed; fix the reported files and stage/commit the fixes.' >&2
    echo 'Format with: zig fmt src build.zig build.zig.zon examples tools' >&2
    exit 1
fi
