import AppKit
@preconcurrency import AVFoundation
import AudioToolbox
import SwiftUI

enum DeviceSelection: Hashable {
    case camera(String)
    case microphone(String)
}

@MainActor
final class DeviceBrowserModel: ObservableObject {
    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var microphones: [AVCaptureDevice] = []
    @Published var selection: DeviceSelection?
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published private(set) var cameraMessage: String?
    @Published private(set) var microphoneMessage: String?
    @Published private(set) var microphoneLevel: CGFloat = 0

    let camera = CameraCapture()
    private let microphone = MicrophoneCapture()

    init() {
        refreshDevices()
        microphone.onLevel = { [weak self] level in
            Task { @MainActor in self?.microphoneLevel = CGFloat(level) }
        }
    }

    func refreshDevices() {
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        ).devices
        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices
        let selectionIsAvailable: Bool
        switch selection {
        case .camera(let id): selectionIsAvailable = cameras.contains { $0.uniqueID == id }
        case .microphone(let id): selectionIsAvailable = microphones.contains { $0.uniqueID == id }
        case .none: selectionIsAvailable = false
        }
        if !selectionIsAvailable {
            selection = nil
        }
        if selection == nil {
            if let camera = cameras.first {
                selection = .camera(camera.uniqueID)
            } else if let microphone = microphones.first {
                selection = .microphone(microphone.uniqueID)
            }
        }
    }

    func stop() {
        camera.stop()
        microphone.stop()
    }

    func select(_ selection: DeviceSelection?) {
        self.selection = selection
        camera.stop()
        microphone.stop()
        cameraMessage = nil
        microphoneMessage = nil
        microphoneLevel = 0

        guard let selection else { return }
        switch selection {
        case .camera(let id):
            guard let device = cameras.first(where: { $0.uniqueID == id }) else { return }
            Task { cameraMessage = await camera.start(device: device) }
        case .microphone(let id):
            guard let device = microphones.first(where: { $0.uniqueID == id }) else { return }
            Task {
                microphoneMessage = await microphone.start(device: device)
            }
        }
    }
}

final class CameraCapture: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.masker.camera")
    private var activeDeviceID: String?

    func start(device: AVCaptureDevice) async -> String? {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            authorized = false
        }
        guard authorized else {
            return "Camera access is unavailable. Enable it in System Settings → Privacy & Security → Camera."
        }

        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                if activeDeviceID != device.uniqueID {
                    session.beginConfiguration()
                    session.inputs.forEach(session.removeInput)
                    session.sessionPreset = .high
                    do {
                        let input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input) else {
                            session.commitConfiguration()
                            continuation.resume(returning: "Unable to use this camera.")
                            return
                        }
                        session.addInput(input)
                        activeDeviceID = device.uniqueID
                        session.commitConfiguration()
                    } catch {
                        session.commitConfiguration()
                        continuation.resume(returning: "Unable to open the camera: \(error.localizedDescription)")
                        return
                    }
                }
                if !session.isRunning { session.startRunning() }
                continuation.resume(returning: session.isRunning ? nil : "Unable to start the camera.")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }
}

final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.masker.microphone")
    private let sampleQueue = DispatchQueue(label: "com.masker.microphone.samples")
    private let audioOutput = AVCaptureAudioDataOutput()
    private var activeDeviceID: String?
    var onLevel: (@Sendable (Float) -> Void)?

    func start(device: AVCaptureDevice) async -> String? {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            authorized = false
        }
        guard authorized else {
            return "Microphone access is unavailable. Enable it in System Settings → Privacy & Security → Microphone."
        }

        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                session.beginConfiguration()
                session.inputs.forEach(session.removeInput)
                session.outputs.forEach(session.removeOutput)
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        continuation.resume(returning: "Unable to use this microphone.")
                        return
                    }
                    session.addInput(input)
                    guard session.canAddOutput(audioOutput) else {
                        session.commitConfiguration()
                        continuation.resume(returning: "Unable to read audio from this microphone.")
                        return
                    }
                    audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)
                    session.addOutput(audioOutput)
                    activeDeviceID = device.uniqueID
                    session.commitConfiguration()
                    session.startRunning()
                    continuation.resume(returning: session.isRunning ? nil : "Unable to start the microphone.")
                } catch {
                    session.commitConfiguration()
                    continuation.resume(returning: "Unable to open the microphone: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            activeDeviceID = nil
            onLevel?(0)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let dataPointer else { return }

        let bytesPerSample = Int(stream.mBitsPerChannel / 8)
        guard bytesPerSample > 0 else { return }
        let sampleCount = min(totalLength, lengthAtOffset) / bytesPerSample
        guard sampleCount > 0 else { return }

        let peak: Float
        if stream.mFormatFlags & kAudioFormatFlagIsFloat != 0 && bytesPerSample == MemoryLayout<Float>.size {
            let samples = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            peak = (0..<sampleCount).reduce(Float.zero) { max($0, abs(samples[$1])) }
        } else if stream.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 && bytesPerSample == MemoryLayout<Int16>.size {
            let samples = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Int16.self)
            peak = (0..<sampleCount).reduce(Float.zero) { max($0, Float(abs(Int32(samples[$1]))) / Float(Int16.max)) }
        } else {
            return
        }
        onLevel?(min(peak, 1))
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
        previewLayer.backgroundColor = NSColor.clear.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.cornerRadius = 14
        previewLayer.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
