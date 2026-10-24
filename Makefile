# FontsMaker — font engine (Swift package + `fontsmaker` CLI), macOS and iOS apps
#
# Quick start after clone:
#   make setup          # install xcodegen (if needed), fetch the reference fonts, generate the project
#   make test           # package tests, then the app tests on macOS and on an iOS simulator
#   make run            # build, install and launch the iOS app on a simulator
#
# Shipping, one command each:
#   make release        # App Store .ipa of the iOS app: build/ios/export/FontsMaker.ipa (not uploaded)
#   make mac notarize   # Developer ID macOS app, notarized and stapled: build/mac/FontsMaker.zip
#   make dist VERSION=x.y.z  # ad hoc signed Mac app + CLI zips for a GitHub release: build/dist/
#
# App/FontsMaker.xcodeproj is generated from App/project.yml via xcodegen — it is not
# hand-edited and not committed. Edit App/project.yml, then `make generate`.

PROJECT       := App/FontsMaker.xcodeproj
SPEC          := App/project.yml
CONFIGURATION := Debug
BUILD         := build
DERIVED       := $(BUILD)/DerivedData
LOGS          := $(BUILD)/logs
BUNDLE_ID     := app.fontsmaker.FontsMaker
# The team goes on the xcodebuild command line only, never into project.yml (the
# convention scripts/ios-bench.sh set): the Mac app and the tests sign ad hoc so they
# run in the test VM without one, and only device and distribution builds need it.
TEAM_ID       := NKJSLB6HBR
SIMULATOR     ?= iPhone 17
SIM_APP       := $(DERIVED)/Build/Products/$(CONFIGURATION)-iphonesimulator/FontsMaker.app
MAC_APP       := $(DERIVED)/Build/Products/$(CONFIGURATION)/FontsMaker.app

# The paired iPhone XR (iOS 18), addressed by UDID rather than name: a rename breaks a
# name, a UDID survives one. Read it from `xcrun xctrace list devices` (the long hex
# form); `xcrun devicectl list devices` prints CoreDevice's own UUID in its Identifier
# column, which is a different number and not what -destination wants.
DEVICE_ID     ?= 00008020-00192DA82128002E
DEVICE_APP    := $(DERIVED)/Build/Products/$(CONFIGURATION)-iphoneos/FontsMaker.app

# The release builds get derived data of their own, because they are the targets
# somebody starts and then walks away from — and walking away means running `make
# test` while one is still going. Two xcodebuilds sharing one path do not queue: they
# delete each other's staging directories part way through. In novel_reader that cost
# a twenty-one minute run which reported "Executed 0 tests", and crashed the suite
# that collided with it — two failures that look like bugs and are not. Same rule as
# never sharing a target directory between two worktrees, for the same reason.
IOS_OUT       := $(BUILD)/ios
IOS_ARCHIVE   := $(IOS_OUT)/FontsMaker.xcarchive
IOS_EXPORT    := $(IOS_OUT)/export
MAC_OUT       := $(BUILD)/mac
MAC_ARCHIVE   := $(MAC_OUT)/FontsMaker.xcarchive
MAC_EXPORT    := $(MAC_OUT)/export
MAC_DIST_APP  := $(MAC_EXPORT)/FontsMaker.app
MAC_ZIP       := $(MAC_OUT)/FontsMaker.zip
# The notarytool keychain profile, shared with wifi_detect. Create it once with
# `xcrun notarytool store-credentials <name> --apple-id <id> --team-id NKJSLB6HBR`.
NOTARY_PROFILE ?= zeyanlin-notary
DIST          := $(BUILD)/dist

.DEFAULT_GOAL := help
.PHONY: help setup generate build build-mac build-ios test test-swift test-mac test-ios cli run run-mac run-device archive ipa release mac notarize dist clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

# --- Setup / housekeeping ---

setup: ## Install xcodegen (if needed), fetch the reference fonts the tests read, generate the project
	@command -v xcodegen > /dev/null || brew install xcodegen
	bash scripts/fetch-fixtures.sh
	$(MAKE) generate

generate: ## Regenerate App/FontsMaker.xcodeproj from App/project.yml (source of truth)
	xcodegen generate --spec $(SPEC)

clean: ## Remove everything this Makefile builds (build/)
	rm -rf $(BUILD)

# --- Build and test ---

build: build-mac build-ios ## Build the macOS app and the iOS app for the simulator

build-mac: generate ## Build the macOS app (ad hoc signed, as in the test VM)
	xcodebuild -project $(PROJECT) -scheme FontsMaker -configuration $(CONFIGURATION) \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) build

build-ios: generate ## Build the iOS app for the simulator
	xcodebuild -project $(PROJECT) -scheme FontsMakerIOS -configuration $(CONFIGURATION) \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath $(DERIVED) build

# Each test run keeps its output in build/logs and fails on a skipped test, which
# xcodebuild and swift test both count as passing.
test: test-swift test-mac test-ios ## Run every test suite below; fails on any skipped test

test-swift: ## Run the package tests (engine and CLI)
	bash scripts/checked-test.sh $(LOGS)/test-swift.log swift test

test-mac: generate ## Run the app's view-model tests on macOS
	bash scripts/checked-test.sh $(LOGS)/test-mac.log \
		xcodebuild test -project $(PROJECT) -scheme FontsMaker -configuration $(CONFIGURATION) \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED)

test-ios: generate ## Run the app's view-model tests on an iOS simulator (SIMULATOR=name)
	@# Tests need a concrete simulator; the generic destination is build-only.
	bash scripts/checked-test.sh $(LOGS)/test-ios.log \
		xcodebuild test -project $(PROJECT) -scheme FontsMakerIOS -configuration $(CONFIGURATION) \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' -derivedDataPath $(DERIVED)

cli: ## Build the release CLI: .build/release/fontsmaker
	swift build -c release
	@echo "CLI → .build/release/fontsmaker"

# --- Run ---

run: build-ios ## Build, then install & launch the iOS app on the simulator (SIMULATOR=name)
	@xcrun simctl boot "$(SIMULATOR)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install "$(SIMULATOR)" "$(SIM_APP)"
	xcrun simctl launch "$(SIMULATOR)" $(BUNDLE_ID)

run-mac: build-mac ## Build, then launch the macOS app
	open "$(MAC_APP)"

run-device: generate ## Build, then install & launch on the connected iPhone (DEVICE_ID=udid)
	@# -allowProvisioningUpdates lets Xcode register the phone with the team and
	@# refresh the development profile instead of failing.
	xcodebuild -project $(PROJECT) -scheme FontsMakerIOS -configuration $(CONFIGURATION) \
		-destination 'platform=iOS,id=$(DEVICE_ID)' -derivedDataPath $(DERIVED) \
		DEVELOPMENT_TEAM=$(TEAM_ID) -allowProvisioningUpdates build
	xcrun devicectl device install app --device $(DEVICE_ID) "$(DEVICE_APP)"
	xcrun devicectl device process launch --device $(DEVICE_ID) --terminate-existing $(BUNDLE_ID)

# --- iOS release: App Store build, needs Xcode signed in to the team's Apple ID ---

release: archive ipa ## Archive + export the App Store .ipa of the iOS app

archive: generate ## Archive a signed Release build of the iOS app (automatic signing)
	rm -rf $(IOS_ARCHIVE)
	xcodebuild -project $(PROJECT) -scheme FontsMakerIOS -configuration Release \
		-destination 'generic/platform=iOS' -derivedDataPath $(IOS_OUT)/DerivedData \
		-archivePath $(IOS_ARCHIVE) DEVELOPMENT_TEAM=$(TEAM_ID) -allowProvisioningUpdates archive

ipa: ## Export the App Store .ipa from the archive (run `make archive` first)
	@# -allowProvisioningUpdates lets the export get the distribution certificate and
	@# the App Store profile from the team's account. The export packs the .ipa with
	@# /usr/bin/rsync, which starts its other end from the first rsync in PATH;
	@# Homebrew's doesn't take Apple's -E and the export fails with "Copy failed", so
	@# the system directories go first.
	rm -rf $(IOS_EXPORT)
	PATH="/usr/bin:/bin:/usr/sbin:/sbin:$$PATH" xcodebuild -exportArchive \
		-archivePath $(IOS_ARCHIVE) \
		-exportOptionsPlist App/ExportOptions-iOS.plist \
		-exportPath $(IOS_EXPORT) \
		-allowProvisioningUpdates
	@echo "IPA → $(IOS_EXPORT)/FontsMaker.ipa  (upload via Transporter)"

# --- macOS release: Developer ID, outside the Mac App Store ---

mac: generate ## Developer ID build of the macOS app, hardened runtime: build/mac/FontsMaker.zip
	@# The project signs the Mac app ad hoc with the hardened runtime off, so it runs in
	@# the test VM without a team. Only this build overrides that, on the command line,
	@# so day-to-day builds stay as they are. CODE_SIGN_STYLE too: the package's
	@# resource bundle target signs automatically, and automatic signing refuses a
	@# named Developer ID identity ("conflicting provisioning settings").
	rm -rf $(MAC_ARCHIVE) $(MAC_EXPORT) $(MAC_ZIP)
	xcodebuild -project $(PROJECT) -scheme FontsMaker -configuration Release \
		-destination 'generic/platform=macOS' -derivedDataPath $(MAC_OUT)/DerivedData \
		-archivePath $(MAC_ARCHIVE) \
		DEVELOPMENT_TEAM=$(TEAM_ID) CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
		ENABLE_HARDENED_RUNTIME=YES archive
	xcodebuild -exportArchive -archivePath $(MAC_ARCHIVE) \
		-exportOptionsPlist App/ExportOptions-macOS.plist -exportPath $(MAC_EXPORT)
	codesign --verify --deep --strict --verbose=2 "$(MAC_DIST_APP)"
	@# Notarization rejects anything else, but only after an upload and a wait.
	@codesign -dvv "$(MAC_DIST_APP)" 2>&1 | grep -q '^Authority=Developer ID Application' \
		|| { echo "mac: $(MAC_DIST_APP) isn't signed with Developer ID" >&2; exit 1; }
	@codesign -dvv "$(MAC_DIST_APP)" 2>&1 | grep -q 'flags=.*(runtime)' \
		|| { echo "mac: $(MAC_DIST_APP) doesn't have the hardened runtime" >&2; exit 1; }
	ditto -c -k --keepParent "$(MAC_DIST_APP)" "$(MAC_ZIP)"
	@echo "Mac app → $(MAC_ZIP)  (signed, not notarized: make notarize)"

notarize: ## Notarize + staple the `make mac` build, zip it again (NOTARY_PROFILE=name)
	@# notarytool says the profile is missing when the screen is merely locked: it
	@# can't read the keychain item then.
	@xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" > /dev/null 2>&1 || { \
		echo "notarize: can't read the notarytool keychain profile \"$(NOTARY_PROFILE)\"." >&2; \
		echo "  If this Mac's screen is locked, unlock it. Otherwise create the profile once:" >&2; \
		echo "  xcrun notarytool store-credentials $(NOTARY_PROFILE) --apple-id <apple id> --team-id $(TEAM_ID)" >&2; \
		echo "  (an app-specific password from account.apple.com), then run make notarize again." >&2; \
		exit 1; }
	xcrun notarytool submit "$(MAC_ZIP)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	@# The staple is the check: it fails unless Apple accepted the submission, and
	@# `xcrun notarytool log <id> --keychain-profile $(NOTARY_PROFILE)` says why not.
	xcrun stapler staple "$(MAC_DIST_APP)"
	@# A zip can't carry the ticket itself; zipped again, the app inside has it.
	rm -f "$(MAC_ZIP)"
	ditto -c -k --keepParent "$(MAC_DIST_APP)" "$(MAC_ZIP)"
	spctl -a -vv -t exec "$(MAC_DIST_APP)"
	@echo "Notarized Mac app → $(MAC_ZIP)"

# --- GitHub release: what .github/workflows/release.yml uploads ---

dist: generate ## Universal ad hoc signed Mac app + CLI zips for a GitHub release (VERSION=x.y.z): build/dist/
	@test -n "$(VERSION)" || { echo "dist: VERSION= is required, e.g. make dist VERSION=0.1.0" >&2; exit 1; }
	@# Ad hoc, as project.yml signs the Mac app: the CI runner has no Developer ID, and
	@# the release notes say how to open an unnotarized app. The iOS app is not here:
	@# an App Store .ipa cannot be installed from a download.
	rm -rf $(DIST)
	xcodebuild -project $(PROJECT) -scheme FontsMaker -configuration Release \
		-destination 'generic/platform=macOS' -derivedDataPath $(DIST)/DerivedData build
	ditto -c -k --keepParent $(DIST)/DerivedData/Build/Products/Release/FontsMaker.app \
		$(DIST)/FontsMaker-$(VERSION)-macos-universal.zip
	@# The CLI reads OpenCC and Unicode data through Bundle.module, which looks for the
	@# resource bundle beside the executable, so the two ship in one folder.
	swift build -c release --arch arm64 --arch x86_64
	mkdir -p $(DIST)/FontsMaker-CLI-$(VERSION)
	bin="$$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)" && \
		cp -R "$$bin/fontsmaker" "$$bin/FontsMaker_FontsMakerKit.bundle" $(DIST)/FontsMaker-CLI-$(VERSION)/
	ditto -c -k --keepParent $(DIST)/FontsMaker-CLI-$(VERSION) $(DIST)/FontsMaker-CLI-$(VERSION)-macos-universal.zip
	@ls -l $(DIST)/*.zip
