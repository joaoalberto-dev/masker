import Foundation
import Combine
import SystemExtensions

enum VirtualDevicePreferences {
    static let appGroup = "group.com.masker.app"
    static let cameraName = "Masker Virtual Camera"
    static let cameraDeviceID = "virtualCamera.sourceDeviceID"
    static let cameraBrightness = "virtualCamera.brightness"
    static let cameraContrast = "virtualCamera.contrast"
    static let cameraWhiteBalance = "virtualCamera.whiteBalance"

    static func set(_ value: Any, forKey key: String) {
        UserDefaults(suiteName: appGroup)?.set(value, forKey: key)
    }
}

@MainActor
final class VirtualDeviceInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published var notice: Notice?
    @Published private(set) var cameraInstalled = false

    private let cameraExtensionID = "com.masker.app.CameraExtension"

    func installCamera() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: cameraExtensionID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func reportMicrophoneUnavailable() {
        notice = Notice(
            title: "Virtual microphone isn’t ready",
            message: "Masker’s Core Audio virtual microphone driver still needs to be implemented and signed before it can be installed in macOS."
        )
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor [weak self] in
            self?.notice = Notice(
                title: "Approval required",
                message: "Open System Settings → Privacy & Security and allow the Masker camera extension."
            )
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor [weak self] in
            self?.cameraInstalled = result == .completed
            if result == .completed {
                self?.notice = Notice(title: "Virtual camera ready", message: "Masker Virtual Camera is now available to apps that use a camera.")
            } else {
                self?.notice = Notice(title: "Restart required", message: "macOS will finish enabling the Masker camera extension after a restart.")
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.notice = Notice(title: "Couldn’t install virtual camera", message: message)
        }
    }
}
