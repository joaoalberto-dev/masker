# Masker

A macOS app for applying real-time camera and microphone filters and making the processed streams available to other apps through virtual devices.

## Planned architecture

- SwiftUI for the app interface and settings.
- AVFoundation for camera and microphone capture.
- Core Image / Metal for video effects.
- AVAudioEngine / Audio Units for audio effects.
- Core Media I/O Camera Extension for the virtual camera.
- Core Audio driver plug-in for the virtual microphone.

## Run locally

Requires macOS 13 or later and Xcode Command Line Tools (`xcode-select --install`).

To run from Xcode, open `Masker.xcodeproj`, select the shared `Masker` scheme and
the `My Mac` destination, then press Run (⌘R). The project uses the same Swift
sources and camera/microphone permission descriptions as the Makefile build.

```sh
make run
```

This builds and opens `build/Masker.app`: a resizable device browser with Camera
and Microphones groups in the sidebar. Selecting a camera shows its live video;
selecting a microphone shows its live input level. Closing the window quits the app.

On first use of each device type, macOS asks for camera or microphone access. You
can change these permissions in System Settings → Privacy & Security → Camera or
Microphone. The app previews the selected device and does not save or transmit media.

```sh
make build  # Build the app without opening it
make test   # Run the XCTest suite
make clean  # Remove build output
```

The XCTest suite is managed by Swift Package Manager and covers logic shared
with the app. Run it with `swift test` or `make test`.

The interface uses SwiftUI hosted in an AppKit window, with AVFoundation for
device discovery and previews. Filters and virtual devices are not implemented yet.
