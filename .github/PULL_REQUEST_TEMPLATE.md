## Summary

- What changed and why?

## Security & Constraints Checklist

- [ ] No C/Objective-C/Java shims or `@cImport(` calls (`sh tools/check-security.sh` passes)
- [ ] Every modified/added source, script, shader, and doc file is at most 600 lines (`zig build lines` / `sh tools/check-snapshot.sh HEAD` passes)
- [ ] Zig files formatted with `zig fmt` and compatible with Zig 0.17.0
- [ ] Any binary assets added or updated under `src/` or `tools/` include verified upstream provenance and updated digests in `tools/binary-assets.sha256`
- [ ] Any CI/workflow or dependency changes preserve minimal `permissions` and `--ignore-scripts`
- [ ] Relevant unit/widget/security tests pass without showing windows or driving the user's screen
