ROOT := $(abspath .)
SWIFT ?= swiftc
SDK ?= $(shell xcrun --sdk macosx --show-sdk-path)
TARGET ?= arm64-apple-macos13
VFS := .build/swift-bridging-vfs.yaml
CLT_SWIFT_INCLUDE := /Library/Developer/CommandLineTools/usr/include/swift
SOURCES := $(wildcard Sources/ProjectSwitcher/*.swift)
BIN := .build/release/ProjectSwitcher
SWIFTFLAGS := -parse-as-library -sdk "$(SDK)" -target $(TARGET)

ifneq ($(wildcard $(CLT_SWIFT_INCLUDE)/bridging.modulemap),)
SWIFTFLAGS += -vfsoverlay "$(VFS)"
VFS_DEP := $(VFS)
endif

.PHONY: build test app dmg install clean

build: $(BIN)

$(VFS): scripts/empty.modulemap
	mkdir -p .build
	printf '%s\n' '{ "version": 0, "case-sensitive": false, "roots": [ { "type": "directory", "name": "$(CLT_SWIFT_INCLUDE)", "contents": [ { "type": "file", "name": "bridging.modulemap", "external-contents": "$(ROOT)/scripts/empty.modulemap" } ] } ] }' > "$@"

$(BIN): $(SOURCES) $(VFS_DEP)
	mkdir -p .build/release
	$(SWIFT) -O $(SWIFTFLAGS) \
		-o "$(BIN)" $(SOURCES) \
		-framework AppKit \
		-framework Carbon \
		-framework ApplicationServices \
		-framework CoreGraphics \
		-framework ServiceManagement \
		-framework SwiftUI

test: $(VFS_DEP)
	mkdir -p .build
	$(SWIFT) $(SWIFTFLAGS) \
		-o .build/TitleParserSmoke \
		Sources/ProjectSwitcher/TitleParser.swift Tests/TitleParserSmoke.swift
	.build/TitleParserSmoke
	$(SWIFT) $(SWIFTFLAGS) \
		-o .build/ScanRootsSmoke \
		Sources/ProjectSwitcher/TitleParser.swift \
		Sources/ProjectSwitcher/OpenProjects.swift \
		Sources/ProjectSwitcher/ScanRoots.swift \
		Tests/ScanRootsSmoke.swift \
		-framework AppKit \
		-framework CoreGraphics
	.build/ScanRootsSmoke

app: test build
	bash scripts/bundle.sh

dmg: app
	bash scripts/make-dmg.sh

install: app
	rm -rf "/Applications/Project Switcher.app"
	cp -R "dist/Project Switcher.app" "/Applications/Project Switcher.app"
	bash scripts/install-close-extension.sh
	@echo "已安装到 /Applications/Project Switcher.app"
	@echo "请在「系统设置 → 隐私与安全性 → 辅助功能」中授权，然后按 ⌥S 唤起。"

clean:
	rm -rf .build dist
