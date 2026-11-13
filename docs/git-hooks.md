# Git hooks

Install the repository's native Git hooks with Git 2.31+, a POSIX shell and
tar (Git Bash on Windows provides both), and Zig 0.17.0:

```sh
sh tools/install-hooks.sh
```

Setup is local to this clone and idempotent. It sets `core.hooksPath` to
`.githooks`. If a hook path is already configured, or an executable hook is
present in Git's default hooks directory, setup stops and preserves it.
In that case, call the repository hooks from your existing hooks instead.
Pass pre-push's original arguments and stdin through when chaining it.

- **Pre-commit** checks the whole staged snapshot, including partially staged
  files and Git's alternate index used by partial commits. Unstaged changes
  and untracked files do not affect the check.
- **Pre-push** checks each pushed commit tip, including branches and tags
  pointing to commits. Identical trees are checked once. Ref deletions and
  tags pointing to non-commit objects are skipped. Intermediate commits are
  not checked separately.

Both run `zig fmt --check src build.zig build.zig.zon examples tools` and
the repository's 600-line checker in an isolated temporary checkout. Only
the parent repository's tracked files are included; initialized submodule
working trees are excluded, as in CI's checkout. Nothing is formatted or
restaged automatically. The temporary checkout is removed on success or
failure; Zig may populate its normal global compiler cache. Snapshot export
uses raw Git blobs: checkout filters and line-ending conversion do not run,
and export attributes cannot omit or rewrite tracked files.
Windows users can keep `core.autocrlf=true`: checks read repository bytes
independently of checkout settings.

Fix formatting in the working tree with `zig fmt`, then stage the intended
changes again. Split files over 600 lines by responsibility. Before pushing,
commit the fixes: the push hook checks committed content, not local fixes.
Full tests and platform builds stay in CI.

Run the same checks manually:

```sh
sh tools/check-snapshot.sh --staged
sh tools/check-snapshot.sh HEAD
sh tools/test-hooks.sh
```

CI uses the same checker on `HEAD` and tests the hooks in disposable repos.
Hooks require installation and can be bypassed (`git commit --no-verify`,
`git push --no-verify`), so CI remains the shared enforcement point.

To uninstall this setup, first verify `git config --local --get core.hooksPath`
prints `.githooks`, then run `git config --local --unset core.hooksPath`.
If you chained these checks into your own hooks, remove those calls instead.
