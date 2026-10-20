import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class CameraController: ObservableObject {
    let capture = CameraCapture()
    @Published private(set) var message: String? = "Starting camera…"

    func start() async {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            granted = false
        }

        guard !Task.isCancelled else { return }
        guard granted else {
            message = "Camera access is unavailable. Enable it in System Settings → Privacy & Security → Camera."
            return
        }
        message = await capture.start()
    }
}

// Configuration and start/stop calls are serialized off the main thread.
final class CameraCapture: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.masker.camera")

    func start() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if session.inputs.isEmpty {
                    guard let device = AVCaptureDevice.default(for: .video) else {
                        continuation.resume(returning: "No camera found.")
                        return
                    }
                    do {
                        let input = try AVCaptureDeviceInput(device: device)
                        session.beginConfiguration()
                        session.sessionPreset = .high
                        guard session.canAddInput(input) else {
                            session.commitConfiguration()
                            continuation.resume(returning: "Unable to use this camera.")
                            return
                        }
                        session.addInput(input)
                        session.commitConfiguration()
                    } catch {
                        continuation.resume(returning: "Unable to open the camera: \(error.localizedDescription)")
                        return
                    }
                }
                if !session.isRunning {
                    session.startRunning()
                }
                continuation.resume(returning: session.isRunning ? nil : "Unable to start the camera.")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {}
}

final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = previewLayer
        previewLayer.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
