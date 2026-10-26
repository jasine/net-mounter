---
name: changelog
description: Generate user-facing changelog from git commits between two tags
disable-model-invocation: true
---

Generate a clean, user-facing changelog for a release.

Arguments: FROM_TAG TO_TAG (e.g., `v1.0.2 v1.1.0`). If omitted, use the two most recent tags.

## Steps

1. Get the two most recent tags if not provided:
   ```bash
   git tag --sort=-v:refname | head -2
   ```

2. Get commits between tags:
   ```bash
   git log --pretty=format:"%s" FROM_TAG..TO_TAG -- NetMounter/ docs/ Casks/
   ```

3. Group commits into categories based on conventional commit prefixes:
   - `feat:` / `feat(...)` → **New Features**
   - `fix:` / `fix(...)` → **Bug Fixes**
   - `refactor:` → **Improvements**
   - `docs:` → **Documentation**
   - Other → **Other Changes**

4. Rewrite each commit message into user-friendly language (remove technical prefixes, expand abbreviations).

5. Output in this format:
   ```markdown
   ## What's New in vX.Y.Z

   ### New Features
   - Feature description

   ### Bug Fixes
   - Fix description

   ### Improvements
   - Improvement description
   ```

Skip empty categories. Keep descriptions concise (one line each).
