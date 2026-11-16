SHELL := /bin/sh
APP := $(CURDIR)/build/TunnelBar.app
# CLT 27.2 未附带 SwiftUI 新宏插件；使用其随包提供的 26.5 SDK。
MACOS_SDK := macosx26.5
CONFIGURATION ?= Debug
# 发布包开启优化，日常调试保留调试符号。
SWIFT_FLAGS := $(if $(filter Release,$(CONFIGURATION)),-O,-D DEBUG -g -Onone)
# 固定使用本机证书，避免构建后签名身份随程序内容改变。
SIGNING_IDENTITY ?= 3CFA98BAD8E3B686B594EF51E23367F2404BDC6C
SOURCES := TunnelBar/Models.swift TunnelBar/ConfigStore.swift TunnelBar/SSHTransport.swift \
	TunnelBar/TunnelManager.swift TunnelBar/AppModel.swift TunnelBar/Notifications.swift \
	TunnelBar/Views.swift TunnelBar/AppDelegate.swift TunnelBar/main.swift

.PHONY: build check icon clean

# 完整 Xcode 可用时使用工程；否则用独立命令行工具编译相同源码。
build:
	@set -eu; \
	if /usr/bin/xcodebuild -version >/dev/null 2>&1; then \
		/usr/bin/xcodebuild -project TunnelBar.xcodeproj -scheme TunnelBar \
			-configuration "$(CONFIGURATION)" -derivedDataPath "$(CURDIR)/build/DerivedData" \
			CONFIGURATION_BUILD_DIR="$(CURDIR)/build" \
			CODE_SIGN_IDENTITY="$(SIGNING_IDENTITY)" CODE_SIGN_STYLE=Manual build; \
	else \
		mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(CURDIR)/build/ModuleCache"; \
		xcrun --sdk "$(MACOS_SDK)" swiftc -emit-executable -module-name TunnelBar \
			-swift-version 5 -sdk "$$(xcrun --sdk "$(MACOS_SDK)" --show-sdk-path)" \
			-target "$$(uname -m)-apple-macosx13.0" \
			-module-cache-path "$(CURDIR)/build/ModuleCache" $(SWIFT_FLAGS) \
			-framework AppKit -framework SwiftUI -framework UserNotifications \
			$(SOURCES) -o "$(APP)/Contents/MacOS/TunnelBar"; \
		cp TunnelBar/Info.plist "$(APP)/Contents/Info.plist"; \
		cp TunnelBar/Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"; \
		printf 'APPL????' > "$(APP)/Contents/PkgInfo"; \
		/usr/bin/codesign --force --sign "$(SIGNING_IDENTITY)" "$(APP)"; \
	fi

# 仅使用临时回环 SSH 服务验证关键转发行为，不接触用户主机配置。
check:
	python3 Tests/run-integration.py

# 从几何源文件生成透明 PNG 和完整 macOS 图标尺寸。
icon:
	xcrun --sdk "$(MACOS_SDK)" swift scripts/generate-app-icon.swift
	@mkdir -p "$(CURDIR)/build/AppIcon.iconset"
	@set -eu; for size in 16 32 128 256 512; do \
		sips -z $$size $$size TunnelBar/Resources/AppIcon.png --out "$(CURDIR)/build/AppIcon.iconset/icon_$${size}x$${size}.png" >/dev/null; \
		double=$$((size * 2)); \
		sips -z $$double $$double TunnelBar/Resources/AppIcon.png --out "$(CURDIR)/build/AppIcon.iconset/icon_$${size}x$${size}@2x.png" >/dev/null; \
	done
	iconutil -c icns "$(CURDIR)/build/AppIcon.iconset" -o TunnelBar/Resources/AppIcon.icns

# 仅移除本项目的构建产物。
clean:
	rm -rf "$(CURDIR)/build"
