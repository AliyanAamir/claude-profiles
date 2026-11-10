.PHONY: all build test app dmg release run clean icon

VERSION := $(shell tr -d '[:space:]' < VERSION)

all: dmg

build:
	swift build

test:
	swift test

icon:
	mkdir -p build && swift scripts/make-icon.swift build/AppIcon.icns

app:
	scripts/build.sh

dmg: app
	scripts/make-dmg.sh

release:
	scripts/release.sh

run: app
	open "dist/Claude Profiles.app"

clean:
	rm -rf .build build dist
