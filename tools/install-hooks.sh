#!/bin/sh
# Opt in locally; never hide an existing hook setup.
set -eu
root=$(git rev-parse --show-toplevel)
cd "$root"
current=$(git config --get core.hooksPath || true)
case "$current" in
    .githooks|"$root/.githooks")
        echo 'nanoui: repository hooks already enabled'
        exit 0
        ;;
    '') ;;
    *)
        printf 'nanoui: keeping existing core.hooksPath: %s\n' "$current" >&2
        echo 'Run the repository checks from your existing hooks; see docs/git-hooks.md.' >&2
        exit 1
        ;;
esac
hooks=$(git rev-parse --git-path hooks)
for hook in "$hooks"/*; do
    case "$hook" in *.sample) continue ;; esac
    if [ -f "$hook" ] && [ -x "$hook" ]; then
        printf 'nanoui: keeping existing executable hook: %s\n' "$hook" >&2
        echo 'Run the repository checks from your existing hooks; see docs/git-hooks.md.' >&2
        exit 1
    fi
done
git config --local core.hooksPath .githooks
echo 'nanoui: enabled pre-commit and pre-push checks'
