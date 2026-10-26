---
name: release
description: Run the full NetMounter release pipeline (build, tag, GitHub release, Homebrew cask update) with pre-flight checks
disable-model-invocation: true
---

## Release NetMounter

Arguments: VERSION (required, semver format like 1.2.3)

### Steps

1. Validate VERSION matches semver pattern `X.Y.Z`
2. Run `cd NetMounter && swift test` — abort if any test fails
3. Check `git status --porcelain` — abort if working tree is dirty
4. Check `git rev-parse v<VERSION>` — abort if tag already exists
5. Run `cd NetMounter && make release VERSION=<VERSION>`
6. Report the GitHub release URL when done
