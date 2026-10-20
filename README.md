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

```sh
make run
```

This builds and opens `build/Masker.app`: a single centered window with a fixed
600 × 400 point content area with a centered live camera preview and “Masker” below it.
Closing the window quits the app.

On first launch, macOS asks for camera access. You can change this permission in
System Settings → Privacy & Security → Camera. The app displays the default camera
without recording video or capturing audio.

```sh
make build  # Build the app without opening it
make clean  # Remove build output
```

The interface uses SwiftUI hosted in an AppKit window, with AVFoundation for the
camera preview. Filters and virtual devices are not implemented yet.
