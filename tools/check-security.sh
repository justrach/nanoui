#!/bin/sh
# Repository & PR security invariants checked in CI and before merging.
set -eu

work=$(mktemp -d "${TMPDIR:-/tmp}/nanoui-sec.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

fail=0

# 1. No C/ObjC/Java/Kotlin shims and no @cImport calls in source or tools.
while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
        *.c|*.cc|*.cpp|*.cxx|*.h|*.hh|*.hpp|*.m|*.mm|*.java|*.kt|*.kts)
            echo "security: disallowed native/JNI shim file: $f" >&2
            fail=1
            ;;
        *.zig)
            if ! awk '{ line=$0; sub(/\/\/.*/, "", line); if (line ~ /@cImport[[:space:]]*\(/) { print FILENAME ":" FNR ": " $0; bad=1 } } END { exit bad }' "$f" >&2; then
                fail=1
            fi
            ;;
    esac
done <<EOF
$(git -c core.quotePath=false ls-files src examples tools)
EOF

# 2. All binary files tracked under src/ and tools/ must match tools/binary-assets.sha256.
manifest="tools/binary-assets.sha256"
if [ ! -f "$manifest" ]; then
    echo "security: missing binary asset manifest: $manifest" >&2
    exit 1
fi

: > "$work/expected.paths"
while IFS= read -r line; do
    case "$line" in
        ""|\#*) continue ;;
    esac
    expected_hash=${line%% *}
    path=${line#"$expected_hash"}
    path=$(printf '%s' "$path" | sed 's/^[[:space:]]*//')
    printf '%s\n' "$path" >> "$work/expected.paths"
    if [ ! -f "$path" ]; then
        echo "security: manifest references missing file: $path" >&2
        fail=1
        continue
    fi
    actual_hash=$(sha256_file "$path")
    if [ "$actual_hash" != "$expected_hash" ]; then
        echo "security: SHA-256 mismatch for $path (expected $expected_hash, got $actual_hash)" >&2
        fail=1
    fi
done < "$manifest"

: > "$work/actual.paths"
while IFS= read -r f; do
    [ -f "$f" ] || continue
    if [ "$(LC_ALL=C tr -cd '\000' < "$f" | wc -c)" -gt 0 ] || \
       printf '%s' "$f" | grep -qiE '\.(bin|woff2|ttf|otf|png|jpg|jpeg|gif|webp|ico|wasm|zip|tar|gz|xz|so|dylib|dll|exe|a|lib)$'; then
        printf '%s\n' "$f" >> "$work/actual.paths"
    fi
done <<EOF
$(git -c core.quotePath=false ls-files src tools)
EOF

LC_ALL=C sort -u "$work/expected.paths" > "$work/expected.sorted"
LC_ALL=C sort -u "$work/actual.paths" > "$work/actual.sorted"
missing_from_manifest=$(LC_ALL=C comm -23 "$work/actual.sorted" "$work/expected.sorted" || true)
if [ -n "$missing_from_manifest" ]; then
    printf 'security: binary asset(s) missing from %s:\n%s\n' "$manifest" "$missing_from_manifest" >&2
    fail=1
fi

# 3. GitHub Actions workflows & npm lockfile supply-chain checks.
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$wf" ] || continue
    if grep -q 'pull_request_target' "$wf"; then
        echo "security: workflow uses unsafe pull_request_target trigger: $wf" >&2
        fail=1
    fi
    if ! grep -q '^permissions:' "$wf" || ! grep -q 'contents: read' "$wf"; then
        echo "security: workflow must declare top-level permissions with contents: read: $wf" >&2
        fail=1
    fi
    if grep -qi 'write-all' "$wf"; then
        echo "security: workflow uses overly broad write-all permissions: $wf" >&2
        fail=1
    fi
    if grep -nE 'npm[[:space:]]+(ci|install)([[:space:]]|$)' "$wf" | grep -qv -- '--ignore-scripts'; then
        echo "security: workflow runs npm ci/install without --ignore-scripts: $wf" >&2
        fail=1
    fi
done

for lock in $(git ls-files '**/package-lock.json' 'package-lock.json'); do
    [ -f "$lock" ] || continue
    if grep -n '"resolved"' "$lock" | grep -qv 'https://registry\.npmjs\.org/'; then
        echo "security: non-npmjs registry resolved URL in $lock" >&2
        fail=1
    fi
    if grep -n '"integrity"' "$lock" | grep -qv '"sha512-'; then
        echo "security: non-sha512 integrity digest in $lock" >&2
        fail=1
    fi
done

# 4. Web JS/HTML runtime hygiene & loopback-only dev server.
for jf in $(git ls-files 'src/web/*.js' 'src/web/*.html' 'tools/web/*.js' 'tools/web/*.mjs'); do
    [ -f "$jf" ] || continue
    if grep -nE '(^|[^[:alnum:]_])(eval|document\.write)[[:space:]]*\(|new[[:space:]]+Function([^[:alnum:]_]|$)|\.innerHTML([^[:alnum:]_]|$)' "$jf" >&2; then
        echo "security: unsafe dynamic DOM/eval sink in $jf" >&2
        fail=1
    fi
done

if [ -f tools/web/serve.mjs ]; then
    if ! grep -q '127\.0\.0\.1' tools/web/serve.mjs || ! grep -q 'realpath' tools/web/serve.mjs || ! grep -q 'nosniff' tools/web/serve.mjs; then
        echo "security: tools/web/serve.mjs missing loopback, realpath, or nosniff guards" >&2
        fail=1
    fi
    if grep -q '0\.0\.0\.0' tools/web/serve.mjs; then
        echo "security: tools/web/serve.mjs must bind loopback only, not 0.0.0.0" >&2
        fail=1
    fi
fi

# 5. High-confidence secret and private key scanning.
if git grep -nE -- '-----BEGIN (RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----|gh[po]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|A(K|S)IA[0-9A-Z]{16}|sk_live_[0-9a-zA-Z]{24,}' -- ':!tools/check-security.sh' >&2; then
    echo "security: potential private key or live credential detected" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "security: all checks passed"
