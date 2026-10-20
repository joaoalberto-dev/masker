APP := build/Masker.app
BINARY := $(APP)/Contents/MacOS/Masker
SOURCES := $(wildcard Sources/Masker/*.swift)
ARCH := $(shell uname -m)

.PHONY: all build run clean

all: build

build: $(BINARY) $(APP)/Contents/Info.plist

$(BINARY): $(SOURCES)
	mkdir -p $(APP)/Contents/MacOS build/module-cache
	xcrun swiftc -parse-as-library -target $(ARCH)-apple-macosx13.0 -module-cache-path build/module-cache $(SOURCES) -o $@

$(APP)/Contents/Info.plist: Resources/Info.plist
	mkdir -p $(APP)/Contents
	cp $< $@

run: build
	open $(APP)

clean:
	rm -rf build
