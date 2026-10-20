import AppKit
import AVFoundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: DeviceBrowserModel

    var body: some View {
        HStack(spacing: 0) {
            if model.columnVisibility != .detailOnly {
                sidebar
                    .frame(width: 250)
                Divider()
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 500)
        .animation(.easeInOut(duration: 0.18), value: model.columnVisibility)
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
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                Spacer()
                Button(action: model.refreshDevices) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Refresh devices")
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 12)

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
        }
        .background(Color(nsColor: .controlBackgroundColor))
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
                CameraDetail(device: device, session: model.camera.session, message: model.cameraMessage)
            } else {
                EmptyDetail(icon: "video", title: "Camera unavailable", message: "Refresh the device list or connect a camera.")
            }
        case .microphone(let id):
            if let device = model.microphones.first(where: { $0.uniqueID == id }) {
                MicrophoneDetail(device: device, level: model.microphoneLevel, message: model.microphoneMessage)
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
    let session: AVCaptureSession
    let message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DetailHeading(title: device.localizedName, subtitle: "Camera preview", icon: "video")

            ZStack {
                CameraPreview(session: session)
                if let message {
                    StatusMessage(icon: "video.slash", text: message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(Color(red: 0.055, green: 0.07, blue: 0.075))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 8) {
                Circle().fill(message == nil ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(message == nil ? "Live preview" : "Camera paused")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(26)
    }
}

private struct MicrophoneDetail: View {
    let device: AVCaptureDevice
    let level: CGFloat
    let message: String?

    private let barPattern: [CGFloat] = [0.34, 0.5, 0.72, 0.45, 0.86, 0.58, 0.38, 0.67, 0.92, 0.54, 0.75, 0.42, 0.62, 0.88, 0.48, 0.7, 0.36, 0.58, 0.82, 0.45, 0.66, 0.9, 0.52, 0.74]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DetailHeading(title: device.localizedName, subtitle: "Microphone input", icon: "mic")

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
                        Text(level > 0.015 ? "Sound detected" : "Listening for sound")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                        Text("Speak or make a sound to check the input level.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.055, green: 0.07, blue: 0.075))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 8) {
                Circle().fill(message == nil ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(message == nil ? "Input level" : "Microphone paused")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(26)
    }
}

private struct DetailHeading: View {
    let title: String
    let subtitle: String
    let icon: String

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

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .left
        accessory.view = toggleButton
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toggleButton.widthAnchor.constraint(equalToConstant: 24),
            toggleButton.heightAnchor.constraint(equalToConstant: 24)
        ])
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
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
