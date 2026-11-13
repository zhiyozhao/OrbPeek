APP := OrbPeek.app
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null)
DMG := OrbPeek-$(VERSION).dmg

.PHONY: check lint build test run package clean

## check: 静态检查 + 单元测试 + 构建（CI 使用同一入口）
check: lint test build

lint:
	plutil -lint Info.plist
	bash -n Scripts/build-app.sh

build:
	swift build

test:
	swift test

## run: 打包 DEV X 签名的 release app，做 5 秒启动冒烟后只关闭该进程
run:
	Scripts/build-app.sh
	@set -eu; \
	"$(APP)/Contents/MacOS/OrbPeek" & pid=$$!; \
	trap 'kill $$pid 2>/dev/null || true' EXIT INT TERM; \
	sleep 5; \
	kill -0 $$pid; \
	echo "OrbPeek launch smoke test passed (5s)"

## package: 复用发布流程的 .app 构建和 DMG 命令
package:
	Scripts/build-app.sh
	rm -rf dmg
	mkdir dmg
	cp -R "$(APP)" dmg/
	ln -s /Applications dmg/Applications
	hdiutil create -volname OrbPeek -srcfolder dmg -ov -format UDZO "$(DMG)"

clean:
	swift package clean
	rm -rf "$(APP)" dmg OrbPeek-*.dmg
