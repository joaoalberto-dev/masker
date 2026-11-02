import AppKit
import AVFoundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: DeviceBrowserModel
    @StateObject private var virtualDevices = VirtualDeviceInstaller()

    var body: some View {
        let isSidebarVisible = model.columnVisibility != .detailOnly

        HStack(spacing: 0) {
            sidebar
                .frame(width: 252)
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .frame(width: isSidebarVisible ? 272 : 0, alignment: .leading)
                .clipped()
                .opacity(isSidebarVisible ? 1 : 0)
                .allowsHitTesting(isSidebarVisible)
                .accessibilityHidden(!isSidebarVisible)
            Rectangle()
                .fill(Color.primary.opacity(isSidebarVisible ? 0.08 : 0))
                .frame(width: isSidebarVisible ? 1 : 0)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, minHeight: 500)
        .animation(.easeInOut(duration: 0.18), value: model.columnVisibility)
        .alert(item: $virtualDevices.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        .onChange(of: model.selection) { model.select($0) }
        .task {
            if model.selection != nil { model.select(model.selection) }
        }
        .onDisappear {
            model.stop()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Devices")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: model.refreshDevices) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Refresh devices")
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 8)

            List(selection: $model.selection) {
                Section("Camera") {
                    if model.cameras.isEmpty {
                        emptyRow("No cameras found", icon: "video.slash")
                    } else {
                        ForEach(model.cameras, id: \.uniqueID) { device in
                            deviceRow(device, icon: "video", selection: .camera(device.uniqueID))
                        }
                    }
                }

                Section("Microphones") {
                    if model.microphones.isEmpty {
                        emptyRow("No microphones found", icon: "mic.slash")
                    } else {
                        ForEach(model.microphones, id: \.uniqueID) { device in
                            deviceRow(device, icon: "mic", selection: .microphone(device.uniqueID))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func deviceRow(_ device: AVCaptureDevice, icon: String, selection: DeviceSelection) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.localizedName)
                    .lineLimit(1)
                Text(device.localizedName.localizedCaseInsensitiveContains("built-in") ? "Built-in" : "Connected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 19)
        }
        .tag(selection)
    }

    private func emptyRow(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.vertical, 3)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .camera(let id):
            if let device = model.cameras.first(where: { $0.uniqueID == id }) {
                CameraDetail(
                    device: device,
                    frame: model.cameraFrame,
                    brightness: $model.cameraBrightness,
                    contrast: $model.cameraContrast,
                    whiteBalance: $model.cameraWhiteBalance,
                    message: model.cameraMessage,
                    onSaveToSystem: virtualDevices.installCamera
                )
            } else {
                EmptyDetail(icon: "video", title: "Camera unavailable", message: "Refresh the device list or connect a camera.")
            }
        case .microphone(let id):
            if let device = model.microphones.first(where: { $0.uniqueID == id }) {
                MicrophoneDetail(
                    device: device,
                    level: model.microphoneLevel,
                    gain: $model.microphoneGain,
                    softness: $model.microphoneSoftness,
                    message: model.microphoneMessage,
                    recordingMessage: model.recordingMessage,
                    isRecording: model.isRecording,
                    recordingURL: model.recordingURL,
                    isPlaying: model.isPlaying,
                    recordingDuration: model.recordingDuration,
                    onRecord: model.startRecording,
                    onStopRecording: model.stopRecording,
                    onTogglePlayback: model.togglePlayback,
                    onSaveToSystem: virtualDevices.reportMicrophoneUnavailable
                )
            } else {
                EmptyDetail(icon: "mic", title: "Microphone unavailable", message: "Refresh the device list or connect a microphone.")
            }
        case .none:
            EmptyDetail(icon: "camera.metering.unknown", title: "No devices found", message: "Connect a camera or microphone to preview it here.")
        }
    }
}

private struct CameraDetail: View {
    let device: AVCaptureDevice
    let frame: CGImage?
    @Binding var brightness: Double
    @Binding var contrast: Double
    @Binding var whiteBalance: Double
    let message: String?
    let onSaveToSystem: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DetailHeading(
                title: device.localizedName,
                subtitle: "Camera preview",
                icon: "video",
                status: message == nil ? (frame == nil ? "Starting" : "Live") : "Unavailable",
                statusColor: message == nil ? (frame == nil ? .secondary : .green) : .orange,
                onSaveToSystem: onSaveToSystem
            )

            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                CameraPreview(frame: frame)
                if let message {
                    StatusMessage(icon: "video.slash", text: message)
                } else if frame == nil {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.white.opacity(0.8))
                        Text("Waiting for video")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            }

            SettingsPanel(onReset: {
                brightness = PreviewControlDefaults.cameraBrightness
                contrast = PreviewControlDefaults.cameraContrast
                whiteBalance = PreviewControlDefaults.cameraWhiteBalance
            }) {
                AdjustmentSlider(label: "Brightness", value: $brightness, range: -1...1, valueText: brightness, format: "%+.2f")
                AdjustmentSlider(label: "Contrast", value: $contrast, range: 0.5...2, valueText: contrast, format: "%.2f×")
                AdjustmentSlider(label: "White balance", value: $whiteBalance, range: -1...1, valueText: whiteBalance, format: "%+.2f")
            }
        }
        .padding(26)
    }
}

private struct MicrophoneDetail: View {
    let device: AVCaptureDevice
    let level: CGFloat
    @Binding var gain: Double
    @Binding var softness: Double
    let message: String?
    let recordingMessage: String?
    let isRecording: Bool
    let recordingURL: URL?
    let isPlaying: Bool
    let recordingDuration: TimeInterval
    let onRecord: () -> Void
    let onStopRecording: () -> Void
    let onTogglePlayback: () -> Void
    let onSaveToSystem: () -> Void

    private let barPattern: [CGFloat] = [0.34, 0.5, 0.72, 0.45, 0.86, 0.58, 0.38, 0.67, 0.92, 0.54, 0.75, 0.42, 0.62, 0.88, 0.48, 0.7, 0.36, 0.58, 0.82, 0.45, 0.66, 0.9, 0.52, 0.74]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DetailHeading(
                title: device.localizedName,
                subtitle: "Record and playback",
                icon: "mic",
                status: message == nil ? (isRecording ? "Recording" : (isPlaying ? "Playing" : (recordingURL == nil ? "Ready" : "Clip ready"))) : "Unavailable",
                statusColor: message == nil ? (isRecording ? .red : .green) : .orange,
                onSaveToSystem: onSaveToSystem
            )

            VStack(spacing: 25) {
                if let message {
                    StatusMessage(icon: "mic.slash", text: message)
                        .padding(.horizontal, 26)
                } else {
                    HStack(alignment: .center, spacing: 5) {
                        ForEach(barPattern.indices, id: \.self) { index in
                            Capsule()
                                .fill(Color(red: 0.42, green: 0.84, blue: 0.58).opacity(level > 0.015 ? 0.45 + Double(level) * 0.55 : 0.22))
                                .frame(width: 5, height: max(5, 118 * barPattern[index] * max(0.08, level)))
                        }
                    }
                    .frame(height: 118)
                    .animation(.easeOut(duration: 0.12), value: level)

                    VStack(spacing: 6) {
                        Text(isRecording ? "Recording filtered audio" : (level > 0.015 ? "Sound detected" : "Microphone ready"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                        Text(isRecording ? "Stop when you’re done. Your filters are applied as you record." : "Record a clip to hear the filtered result.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.58))
                    }

                    HStack(spacing: 10) {
                        Button(action: isRecording ? onStopRecording : onRecord) {
                            Label(isRecording ? "Stop Recording" : "Record", systemImage: isRecording ? "stop.fill" : "record.circle")
                                .frame(minWidth: 130)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isRecording ? .red : .accentColor)
                        .controlSize(.large)

                        if recordingURL != nil {
                            Button(action: onTogglePlayback) {
                                Label(isPlaying ? "Stop Playback" : "Play Recording", systemImage: isPlaying ? "stop.fill" : "play.fill")
                                    .frame(minWidth: 130)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            Text(String(format: "%.1f s", recordingDuration))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let recordingMessage {
                        Text(recordingMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            }

            SettingsPanel(onReset: {
                gain = PreviewControlDefaults.microphoneGain
                softness = PreviewControlDefaults.microphoneSoftness
            }) {
                AdjustmentSlider(label: "Gain", value: $gain, range: 0...2, valueText: gain, format: "%.2f×")
                AdjustmentSlider(label: "Soften voice", value: $softness, range: 0...0.95, valueText: softness, format: "%.0f%%", multiplier: 100)
            }
        }
        .padding(26)
    }
}

private struct SettingsPanel<Content: View>: View {
    let onReset: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recording filters")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Reset")
                    .accessibilityLabel("Reset")
                    .accessibilityHint("Restores the recording filters to their defaults")
            }
            content
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct AdjustmentSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueText: Double
    let format: String
    var multiplier: Double = 1

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(String(format: format, valueText * multiplier))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(label) value")
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(label)
        }
    }
}

private struct DetailHeading: View {
    let title: String
    let subtitle: String
    let icon: String
    let status: String
    let statusColor: Color
    let onSaveToSystem: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onSaveToSystem) {
                Label("Save to System", systemImage: "externaldrive.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Save this filtered device to macOS")
            .accessibilityHint("Adds this filtered device to macOS when virtual device support is available")
            Text(status)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(statusColor.opacity(0.11), in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Status: \(status)")
        }
    }
}

private struct StatusMessage: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(24)
    }
}

private struct EmptyDetail: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: DeviceBrowserModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = DeviceBrowserModel()
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: ContentView(model: model))

        let toggleButton = NSButton(
            image: NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Toggle sidebar")!,
            target: self,
            action: #selector(toggleSidebar)
        )
        toggleButton.isBordered = false
        toggleButton.bezelStyle = .regularSquare
        toggleButton.imagePosition = .imageOnly
        toggleButton.imageScaling = .scaleProportionallyDown
        toggleButton.contentTintColor = .secondaryLabelColor
        toggleButton.toolTip = "Toggle sidebar"
        toggleButton.setAccessibilityLabel("Toggle sidebar")

        // AppKit owns the accessory's frame; constrain only its content.
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.addSubview(toggleButton)
        NSLayoutConstraint.activate([
            toggleButton.centerXAnchor.constraint(equalTo: accessoryView.centerXAnchor),
            toggleButton.centerYAnchor.constraint(equalTo: accessoryView.centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 24),
            toggleButton.heightAnchor.constraint(equalToConstant: 24)
        ])
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .left
        accessory.view = accessoryView
        window.addTitlebarAccessoryViewController(accessory)

        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleSidebar() {
        guard let model else { return }
        model.columnVisibility = model.columnVisibility == .detailOnly ? .all : .detailOnly
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
enum MaskerApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(title: "Masker", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Masker")
        appMenu.addItem(
            withTitle: "Quit Masker",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        app.mainMenu = mainMenu

        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
