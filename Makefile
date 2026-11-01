.PHONY: build run app dmg clean

build:
	swift build

run: build
	swift run CleanMyiPhone $(ARGS)

app:
	chmod +x scripts/make-app.sh
	scripts/make-app.sh release

# 发给别人用：通用二进制（Apple 芯片 + Intel）+ ad-hoc 签名 + DMG
dmg:
	chmod +x scripts/make-dmg.sh
	scripts/make-dmg.sh

clean:
	rm -rf .build build .buildtmp dist
