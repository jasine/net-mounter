---
name: security-check
description: Scan Swift code for shell injection, thread safety, and credential handling issues
---

Scan the current diff (`git diff HEAD`) for common security issues in Swift/macOS code.

## Check Categories

1. **Shell injection**: Any string interpolation inside shell commands (`Process`, `osascript`, `do shell script`). Verify all interpolated values pass through proper escaping (`shellEscape` + `appleScriptEscape` for osascript paths).

2. **Thread safety**: Identify `@State`/`@Published`/dictionary mutations from background threads. All UI state and non-thread-safe collections must be accessed on the main thread. Check that `completion` handlers from `MountingManager` dispatch to main.

3. **Credential handling**: Ensure passwords are never logged, never embedded in URLs without percent-encoding, and only stored via `KeychainManager`. Check that Keychain save failures are handled.

4. **Privilege escalation**: Any use of `with administrator privileges` in osascript must have its input fully escaped. Flag unescaped user input in admin shell commands.

## Output

For each finding, report:
- File and line number
- Category (injection / thread-safety / credentials / privilege)
- One-line description
- Severity (high / medium / low)

If no issues found, report "No security issues detected."
