APP := build/Masker.app
DERIVED_DATA := build/DerivedData
PRODUCT := $(DERIVED_DATA)/Build/Products/Debug/Masker.app

.PHONY: all build run test clean

all: build

build:
	xcodebuild build -project Masker.xcodeproj -scheme Masker -configuration Debug -destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA)
	rm -rf $(APP)
	cp -R $(PRODUCT) $(APP)

run: build
	open $(APP)

test:
	swift test

clean:
	rm -rf build
