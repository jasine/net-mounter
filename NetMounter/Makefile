# Makefile for NetMounter

.PHONY: run build package dmg clean

# Default target
all: run

# Run the application (Debug mode)
run:
	swift run

# Build the application (Release mode)
build:
	swift build -c release

# Package the application into an .app bundle
package:
	chmod +x package_app.sh
	./package_app.sh

# Create DMG for distribution
dmg: package
	@echo "Creating DMG..."
	@rm -rf dmg_temp NetMounter.dmg
	@mkdir -p dmg_temp
	@cp -r NetMounter.app dmg_temp/
	@ln -s /Applications dmg_temp/Applications
	@hdiutil create -volname "NetMounter" -srcfolder dmg_temp -ov -format UDZO NetMounter.dmg
	@rm -rf dmg_temp
	@echo "Done! Created NetMounter.dmg"

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build
	rm -rf NetMounter.app
	rm -rf NetMounter.dmg

