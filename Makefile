.PHONY: generate build run install clean

# Generate the Xcode project from project.yml
generate:
	xcodegen generate

# Build the app in Release mode.
# The post-build `codesign --force --sign - --deep` call re-applies an ad-hoc
# signature to the whole bundle (including the Widget extension). Without it,
# incremental builds can leave stale CodeResources artifacts that don't match
# the actual bundle contents, causing macOS to refuse to launch the app with
# `_LSOpenURLsWithCompletionHandler() failed with error -600`. This is a
# personal-fork addition; upstream uses GitHub Actions to ship a real signature.
build: generate
	xcodebuild \
		-project ClaudeGod.xcodeproj \
		-scheme ClaudeGod \
		-configuration Release \
		-derivedDataPath build \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO
	codesign --force --sign - --deep \
		"build/Build/Products/Release/Claude God.app"

# Open in Xcode
open: generate
	open ClaudeGod.xcodeproj

# Build and run
run: build
	open "build/Build/Products/Release/Claude God.app"

# Install the freshly-built app to /Applications, replacing any prior copy.
# This is the recommended way to use the personal fork day-to-day: avoids the
# Launch Services drift where macOS keeps launching a stale /Applications copy
# instead of the current build-directory binary, which manifests as
# `_LSOpenURLsWithCompletionHandler() failed with error -600`.
install: build
	@pkill -9 -f "Claude God.app/Contents/MacOS" || true
	@sleep 1
	rm -rf "/Applications/Claude God.app"
	cp -R "build/Build/Products/Release/Claude God.app" /Applications/
	codesign --force --sign - --deep "/Applications/Claude God.app"
	open "/Applications/Claude God.app"

# Create a DMG
dmg: build
	mkdir -p dmg-contents
	cp -R "build/Build/Products/Release/Claude God.app" dmg-contents/
	ln -sf /Applications dmg-contents/Applications
	hdiutil create \
		-volname "Claude God" \
		-srcfolder dmg-contents \
		-ov \
		-format UDZO \
		ClaudeGod.dmg
	rm -rf dmg-contents

# Clean build artifacts
clean:
	rm -rf build ClaudeGod.xcodeproj ClaudeGod.dmg dmg-contents
