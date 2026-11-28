APP := OrbPeek.app
VERSION := $(shell Scripts/version.sh 2>/dev/null)
DMG := OrbPeek-$(VERSION).dmg

.PHONY: check lint build test run package clean

## check: 静态检查 + 单元测试 + 构建（CI 使用同一入口）
check: lint test build

lint:
	plutil -lint Info.plist
	bash -n Scripts/build-app.sh
	bash -n Scripts/version.sh
	bash -n Scripts/release-notes.sh
	Scripts/version.sh >/dev/null
	Scripts/release-notes.sh 1.1.0 | grep -q '修复'
	Scripts/release-notes.sh 1.1.2 | grep -q -- '--login-item-status'
	Scripts/release-notes.sh 1.1.3 | grep -q 'Control + Command'
	Scripts/release-notes.sh "$$(Scripts/version.sh)" | grep -q '^[-*] '

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
	Scripts/version.sh >/dev/null
	Scripts/build-app.sh
	rm -rf dmg
	mkdir dmg
	cp -R "$(APP)" dmg/
	ln -s /Applications dmg/Applications
	hdiutil create -volname OrbPeek -srcfolder dmg -ov -format UDZO "$(DMG)"

clean:
	swift package clean
	rm -rf "$(APP)" dmg OrbPeek-*.dmg
