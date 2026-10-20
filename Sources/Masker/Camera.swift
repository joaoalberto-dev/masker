import AppKit
@preconcurrency import AVFoundation
import AudioToolbox
import CoreImage
import ImageIO
import Security
@preconcurrency import SystemExtensions
import SwiftUI

enum DeviceSelection: Hashable {
    case camera(String)
    case microphone(String)
}

enum MicrophoneLevel {
    static func peak(in samples: UnsafeBufferPointer<Float>) -> Float? {
        guard !samples.isEmpty else { return nil }
        return min(samples.reduce(Float.zero) { max($0, abs($1)) }, 1)
    }

    static func peak(in samples: UnsafeBufferPointer<Int16>) -> Float? {
        guard !samples.isEmpty else { return nil }
        let peak = samples.reduce(Int32.zero) { max($0, abs(Int32($1))) }
        return min(Float(peak) / Float(Int16.max), 1)
    }
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
    @Published var cameraBrightness = 0.0
    @Published private(set) var isCameraPublished = false
    @Published private(set) var publishMessage: String?

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
        camera.endPublishing()
        microphone.stop()
    }

    func select(_ selection: DeviceSelection?) {
        self.selection = selection
        if isCameraPublished { stopPublishingCamera() }
        camera.stop()
        camera.endPublishing()
        microphone.stop()
        isCameraPublished = false
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

    func publishCamera() {
        publishMessage = nil
        camera.setBrightness(cameraBrightness)
        camera.beginPublishing()
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: "com.masker.app.CameraExtension",
            queue: .main
        )
        CameraExtensionActivation.shared.activate(request, onApprovalRequired: { [weak self] in
            self?.publishMessage = "Approve Masker Camera in System Settings → Privacy & Security to finish publishing."
        }) { [weak self] message in
            self?.publishMessage = message
            self?.isCameraPublished = message == nil
            if message != nil { self?.camera.endPublishing() }
        }
    }

    func stopPublishingCamera() {
        camera.endPublishing()
        isCameraPublished = false
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: "com.masker.app.CameraExtension",
            queue: .main
        )
        CameraExtensionActivation.shared.deactivate(request) { [weak self] message in
            self?.publishMessage = message
        }
    }
}

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.masker.camera")
    private let sampleQueue = DispatchQueue(label: "com.masker.camera.frames", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let imageContext = CIContext()
    private let brightnessLock = NSLock()
    private var brightness: CGFloat = 0
    private var shouldPublish = false
    private var publishGeneration: UInt64 = 0
    private var activeDeviceID: String?

    override init() {
        super.init()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
    }

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
                        if session.canAddOutput(videoOutput) {
                            session.addOutput(videoOutput)
                        }
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

    func setBrightness(_ value: Double) {
        brightnessLock.lock()
        brightness = CGFloat(value)
        brightnessLock.unlock()
    }

    func beginPublishing() {
        brightnessLock.lock()
        shouldPublish = true
        publishGeneration &+= 1
        brightnessLock.unlock()
    }

    func endPublishing() {
        brightnessLock.lock()
        shouldPublish = false
        publishGeneration &+= 1
        brightnessLock.unlock()
        if let url = CameraFrameStore.frameURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        brightnessLock.lock()
        let amount = brightness
        let publishing = shouldPublish
        let generation = publishGeneration
        brightnessLock.unlock()
        guard publishing,
              let url = CameraFrameStore.frameURL,
              let filter = CIFilter(name: "CIColorControls") else { return }
        filter.setValue(CIImage(cvPixelBuffer: pixelBuffer), forKey: kCIInputImageKey)
        filter.setValue(amount, forKey: kCIInputBrightnessKey)
        guard let outputImage = filter.outputImage,
              let data = imageContext.jpegRepresentation(of: outputImage, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) else { return }
        brightnessLock.lock()
        guard shouldPublish, publishGeneration == generation else {
            brightnessLock.unlock()
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // A later frame will retry writing to the shared camera frame location.
        }
        brightnessLock.unlock()
    }
}

enum CameraFrameStore {
    static let frameURL: URL? = {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
              let group = groups.first,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container.appendingPathComponent("published-camera.jpg")
    }()
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

        let peak: Float?
        if stream.mFormatFlags & kAudioFormatFlagIsFloat != 0 && bytesPerSample == MemoryLayout<Float>.size {
            let samples = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            peak = MicrophoneLevel.peak(in: UnsafeBufferPointer(start: samples, count: sampleCount))
        } else if stream.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 && bytesPerSample == MemoryLayout<Int16>.size {
            let samples = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Int16.self)
            peak = MicrophoneLevel.peak(in: UnsafeBufferPointer(start: samples, count: sampleCount))
        } else {
            return
        }
        if let peak { onLevel?(peak) }
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
