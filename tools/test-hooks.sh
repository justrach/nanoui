#!/bin/sh
# Integration tests use only disposable repositories, indices and compiler caches.
set -eu
source_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/nanoui-hook-tests.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_PARAMETERS
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=0
export ZIG_GLOBAL_CACHE_DIR="$work/zig-global"
repo="$work/repo"
remote="$work/remote.git"
git init -q "$repo"
git init -q --bare "$remote"
cd "$repo"
git config user.name 'Hook Test'
git config user.email 'hook-test@example.invalid'
git config commit.gpgsign false
git config tag.gpgsign false
# Normalize copied fixtures even when the source checkout uses CRLF on Windows.
git config core.autocrlf input
mkdir .githooks src examples tools
cp "$source_root"/.githooks/pre-* .githooks/
cp "$source_root"/tools/check-snapshot.sh "$source_root"/tools/install-hooks.sh tools/
cp "$source_root/tools/lines.zig" tools/
chmod +x .githooks/*
printf 'pub const answer = 1;\n' > src/main.zig
printf 'pub const keep = true;\n' > src/keep.zig
printf 'pub const example = true;\n' > examples/example.zig
printf 'pub const build_fixture = true;\n' > build.zig
printf '.{}\n' > build.zig.zon
git add .

fail() { printf 'hook test failed: %s\n' "$*" >&2; exit 1; }
ok() {
    if ! "$@" >"$work/result" 2>&1; then
        cat "$work/result" >&2
        fail "expected success: $*"
    fi
}
reject() {
    if "$@" >"$work/result" 2>&1; then
        fail "expected failure: $*"
    fi
}
contains() {
    tr '\134' '/' < "$work/result" | grep -Fq -- "$1" || {
        cat "$work/result" >&2
        fail "missing diagnostic: $1"
    }
}
unchanged() {
    [ "$(git write-tree)" = "$index_before" ] || fail 'hook changed staged contents'
    [ "$(git hash-object src/main.zig)" = "$file_before" ] || fail 'hook changed working contents'
}

ok sh tools/install-hooks.sh
ok sh tools/install-hooks.sh
[ "$(git config --local --get core.hooksPath)" = .githooks ] || fail 'installation'
ok git commit -qm initial
good=$(git rev-parse HEAD)
echo 'ok: installation, idempotence and a real commit'

# A formatted working file must not conceal a bad staged file.
printf 'pub const answer=2;\n' > src/main.zig
git add src/main.zig
printf 'pub const answer = 2;\n' > src/main.zig
index_before=$(git write-tree)
file_before=$(git hash-object src/main.zig)
reject git commit -qm 'bad staged formatting'
contains 'src/main.zig'
unchanged
echo 'ok: partial staging checks the index and leaves both versions intact'

# The opposite partial staging is valid, and must preserve local edits.
git add src/main.zig
printf 'pub const answer=3;\n' > src/main.zig
index_before=$(git write-tree)
file_before=$(git hash-object src/main.zig)
ok git commit -qm 'good staged formatting'
unchanged
good=$(git rev-parse HEAD)
ok git push -q "$remote" HEAD:refs/heads/main
unchanged
echo 'ok: commit and push ignore unformatted working-tree edits'

# A committed formatting failure cannot be fixed by staging a local fix.
git add src/main.zig
git -c core.hooksPath=/dev/null commit -qm 'bad outgoing snapshot'
bad=$(git rev-parse HEAD)
printf 'pub const answer = 3;\n' > src/main.zig
git add src/main.zig
index_before=$(git write-tree)
file_before=$(git hash-object src/main.zig)
reject git push -q "$remote" HEAD:refs/heads/main
contains 'src/main.zig'
unchanged
[ "$(git --git-dir="$remote" rev-parse refs/heads/main)" = "$good" ] || fail 'rejected push reached remote'
echo 'ok: a real push rejects bad committed content despite staged fixes'

zeros=0000000000000000000000000000000000000000
updates="$work/updates"
printf 'refs/heads/good %s refs/heads/good %s\nrefs/heads/bad %s refs/heads/bad %s\n' "$good" "$zeros" "$bad" "$zeros" > "$updates"
reject sh .githooks/pre-push < "$updates"
contains 'refs/heads/bad'
echo 'ok: multiple pushed refs are all read'

printf '(delete) %s refs/heads/old %s\n' "$zeros" "$bad" > "$updates"
ok sh .githooks/pre-push < "$updates"
blob=$(printf 'a non-commit tag' | git hash-object -w --stdin)
printf 'refs/tags/blob %s refs/tags/blob %s\n' "$blob" "$zeros" > "$updates"
ok sh .githooks/pre-push < "$updates"
git tag -a -m fixture fixture "$good"
tag=$(git rev-parse refs/tags/fixture)
printf 'refs/heads/good %s refs/heads/good %s\nrefs/tags/fixture %s refs/tags/fixture %s\n' "$good" "$zeros" "$tag" "$zeros" > "$updates"
ok sh .githooks/pre-push < "$updates"
[ "$(awk '/nanoui: checking pushed ref/ { n++ } END { print n+0 }' "$work/result")" = 1 ] || fail 'duplicate tree was checked twice'
echo 'ok: deletions, non-commit tags, annotated tags and duplicate trees'

# An alternate index must be honored without changing the normal one.
index_before=$(git write-tree)
bad_blob=$(printf 'pub const answer=4;\n' | git hash-object -w --stdin)
GIT_INDEX_FILE="$work/alternate" git read-tree "$good"
GIT_INDEX_FILE="$work/alternate" git update-index --cacheinfo "100644,$bad_blob,src/main.zig"
reject env GIT_INDEX_FILE="$work/alternate" sh .githooks/pre-commit
contains 'src/main.zig'
[ "$(git write-tree)" = "$index_before" ] || fail 'alternate index check changed normal index'
echo 'ok: alternate index'

# A linked worktree has its own index and a shared object directory.
normal_tree=$(git write-tree)
linked="$work/linked checkout"
git worktree add -q --detach "$linked" "$good"
cd "$linked"
printf 'pub const answer=8;\n' > src/main.zig
git add src/main.zig
index_before=$(git write-tree)
file_before=$(git hash-object src/main.zig)
reject git commit -qm 'bad linked-worktree snapshot'
contains 'src/main.zig'
unchanged
cd "$repo"
[ "$(git write-tree)" = "$normal_tree" ] || fail 'linked check changed original index'
echo 'ok: linked worktree with spaces and a shared object directory'

# Neither archive attributes nor a smudge filter may conceal staged errors.
git reset -q --hard "$good"
git config filter.format.smudge 'sed "s/answer=9/answer = 9/"'
printf 'src/main.zig filter=format export-ignore\n' > .gitattributes
printf 'pub const answer=9;\n' > src/main.zig
git add .gitattributes src/main.zig
printf 'pub const answer = 9;\n' > src/main.zig
index_before=$(git write-tree)
file_before=$(git hash-object src/main.zig)
reject sh .githooks/pre-commit
contains 'src/main.zig'
unchanged
git config --unset filter.format.smudge
echo 'ok: export-ignore and checkout filters cannot hide staged formatting'

# Git's exporter must preserve paths containing spaces, newlines and glob chars.
git reset -q --hard "$good"
odd=$(printf 'odd name\n[1].zig')
# Win32 rejects newlines in filenames; retain the spaces and glob characters.
case $(uname -s) in MINGW*|MSYS*|CYGWIN*) odd='odd name [1].zig' ;; esac
git mv src/main.zig "src/$odd"
ok sh .githooks/pre-commit
git rm -qf "src/$odd"
ok sh .githooks/pre-commit
echo 'ok: unusual renamed paths and staged deletions'

awk 'BEGIN { for (n=0; n<601; n++) print "line" }' > src/long.txt
git add src/long.txt
printf 'short\n' > src/long.txt
reject sh .githooks/pre-commit
contains 'src/long.txt: 601 lines'
git rm -qf src/long.txt
awk 'BEGIN { for (n=0; n<601; n++) print "untracked" }' > src/untracked.txt
ok sh .githooks/pre-commit
echo 'ok: staged line-limit failures and unrelated untracked files'

git config --local core.hooksPath custom-hooks
reject sh tools/install-hooks.sh
[ "$(git config --get core.hooksPath)" = custom-hooks ] || fail 'overwrote configured hook path'
git config --local --unset core.hooksPath
printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
existing=$(git hash-object .git/hooks/pre-commit)
reject sh tools/install-hooks.sh
[ "$(git hash-object .git/hooks/pre-commit)" = "$existing" ] || fail 'overwrote existing hook'
if git config --get core.hooksPath >/dev/null; then fail 'hid an existing hook'; fi
echo 'ok: setup preserves existing configuration and executable hooks'
echo 'all hook integration tests passed'
