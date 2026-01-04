# Makefile for NetMounter

.PHONY: run build package clean

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

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build
	rm -rf NetMounter.app
