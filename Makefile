APP := build/DerivedData/Build/Products/Debug/Masker.app
DERIVED_DATA := build/DerivedData
TEAM_ID ?=

ifneq ($(strip $(TEAM_ID)),)
SIGNING_ARGS := CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY=Apple\ Development DEVELOPMENT_TEAM=$(TEAM_ID) CODE_SIGNING_ALLOWED=YES
else
SIGNING_ARGS := CODE_SIGNING_ALLOWED=NO
endif

.PHONY: all build run test clean

all: build

build:
	xcodebuild -project Masker.xcodeproj -scheme Masker -configuration Debug -derivedDataPath $(DERIVED_DATA) $(SIGNING_ARGS)

run: build
	open $(APP)

test:
	swift test

clean:
	rm -rf build
