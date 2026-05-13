# Makefile for NetMounter

.PHONY: run build package dmg clean release

# Default target
all: run

# Run the application (Debug mode)
run:
	swift run

# Build the application (Release mode)
build:
	swift build -c release

# Package the application into an .app bundle
# Usage: make package [VERSION=x.y.z]
package: build
	chmod +x package_app.sh
	./package_app.sh $(VERSION)

# Create DMG for distribution
# Usage: make dmg [VERSION=x.y.z]
dmg: package
	@echo "Creating DMG..."
	@rm -rf dmg_temp NetMounter.dmg
	@mkdir -p dmg_temp
	@cp -r NetMounter.app dmg_temp/
	@ln -s /Applications dmg_temp/Applications
	@hdiutil create -volname "NetMounter" -srcfolder dmg_temp -ov -format UDZO NetMounter.dmg
	@rm -rf dmg_temp
	@echo "Done! Created NetMounter.dmg"

# Full release pipeline
# Usage: make release VERSION=x.y.z
release:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make release VERSION=x.y.z"; exit 1; fi
	@echo "==> Releasing NetMounter v$(VERSION)"
	@echo ""
	@# 1. Preflight checks
	@echo "--- Preflight checks ---"
	@if [ -n "$$(git status --porcelain)" ]; then echo "Error: working tree is dirty. Commit or stash first."; exit 1; fi
	@if git rev-parse "v$(VERSION)" >/dev/null 2>&1; then echo "Error: tag v$(VERSION) already exists."; exit 1; fi
	@echo "OK"
	@echo ""
	@# 2. Update version in package_app.sh (Info.plist source of truth)
	@echo "--- Updating versions ---"
	@sed -i '' 's/VERSION="$${1:-[^"]*}"/VERSION="$${1:-$(VERSION)}"/' package_app.sh
	@# 3. Update version in docs/index.html
	@sed -i '' 's/v[0-9]*\.[0-9]*\.[0-9]* • macOS/v$(VERSION) • macOS/' ../docs/index.html
	@# 4. Update version in Casks/netmounter.rb (sha256 updated later)
	@sed -i '' 's/version "[^"]*"/version "$(VERSION)"/' ../Casks/netmounter.rb
	@echo "Updated: package_app.sh, docs/index.html, Casks/netmounter.rb"
	@echo ""
	@# 5. Build, package, DMG
	@echo "--- Building ---"
	$(MAKE) dmg VERSION=$(VERSION)
	@echo ""
	@# 6. Update Cask sha256
	@echo "--- Updating Cask sha256 ---"
	@SHA256=$$(shasum -a 256 NetMounter.dmg | cut -d' ' -f1) && \
	sed -i '' "s/sha256 \"[^\"]*\"/sha256 \"$$SHA256\"/" ../Casks/netmounter.rb && \
	echo "sha256: $$SHA256"
	@echo ""
	@# 7. Commit version bump
	@echo "--- Committing ---"
	@git add package_app.sh ../docs/index.html ../Casks/netmounter.rb
	@git commit -m "release: v$(VERSION)"
	@echo ""
	@# 8. Tag
	@echo "--- Tagging v$(VERSION) ---"
	@git tag "v$(VERSION)"
	@echo ""
	@# 9. Push
	@echo "--- Pushing ---"
	@git push origin main --tags
	@echo ""
	@# 10. GitHub Release
	@echo "--- Creating GitHub Release ---"
	@PREV_TAG=$$(git tag --sort=-v:refname | sed -n '2p') && \
	CHANGES=$$(git log --pretty=format:"- %s" "$$PREV_TAG..v$(VERSION)" -- . ../docs ../Casks | grep -v "^- release:") && \
	gh release create "v$(VERSION)" NetMounter.dmg \
		--title "NetMounter v$(VERSION)" \
		--notes "$$(printf '## NetMounter v$(VERSION)\n\n### Changes\n'"$$CHANGES"'\n\n### Install via Homebrew\n```bash\nbrew tap jasine/tap\nbrew install --cask netmounter\n```')"
	@echo ""
	@# 11. Update Homebrew tap
	@echo "--- Updating Homebrew tap ---"
	@CASK_CONTENT=$$(cat ../Casks/netmounter.rb) && \
	gh api repos/jasine/homebrew-tap/contents/Casks/netmounter.rb \
		--method PUT \
		-f message="Update netmounter to $(VERSION)" \
		-f content="$$(echo "$$CASK_CONTENT" | base64)" \
		-f sha="$$(gh api repos/jasine/homebrew-tap/contents/Casks/netmounter.rb -q '.sha')" \
		>/dev/null
	@echo ""
	@echo "==> Released NetMounter v$(VERSION)"

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build
	rm -rf NetMounter.app
	rm -rf NetMounter.dmg
