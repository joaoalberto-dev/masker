import AppKit
@preconcurrency import AVFoundation
import AudioToolbox
import CoreImage
import SwiftUI

enum DeviceSelection: Hashable {
    case camera(String)
    case microphone(String)
}

enum MicrophoneLevel {
    static func adjusted(_ level: Float, gain: Float, softness: Float, previous: Float) -> Float {
        let gained = min(max(level * gain, 0), 1)
        let clampedSoftness = min(max(softness, 0), 1)
        return previous * clampedSoftness + gained * (1 - clampedSoftness)
    }

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

enum CameraAdjustment {
    static func brightnessFilterValue(for value: Float) -> Float { min(max(value, -1), 1) }
    static func contrastFilterValue(for value: Float) -> Float { min(max(value, 0.5), 2) }
}

enum PreviewControlDefaults {
    static let cameraBrightness = 0.0
    static let cameraContrast = 1.0
    static let cameraWhiteBalance = 0.0
    static let microphoneGain = 1.0
    static let microphoneSoftness = 0.0
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
    @Published private(set) var cameraFrame: CGImage?
    @Published var cameraBrightness: Double = PreviewControlDefaults.cameraBrightness { didSet { camera.configure(brightness: Float(cameraBrightness), contrast: Float(cameraContrast), whiteBalance: Float(cameraWhiteBalance)) } }
    @Published var cameraContrast: Double = PreviewControlDefaults.cameraContrast { didSet { camera.configure(brightness: Float(cameraBrightness), contrast: Float(cameraContrast), whiteBalance: Float(cameraWhiteBalance)) } }
    @Published var cameraWhiteBalance: Double = PreviewControlDefaults.cameraWhiteBalance { didSet { camera.configure(brightness: Float(cameraBrightness), contrast: Float(cameraContrast), whiteBalance: Float(cameraWhiteBalance)) } }
    @Published var microphoneGain: Double = PreviewControlDefaults.microphoneGain { didSet { microphone.configure(gain: Float(microphoneGain), softness: Float(microphoneSoftness)) } }
    @Published var microphoneSoftness: Double = PreviewControlDefaults.microphoneSoftness { didSet { microphone.configure(gain: Float(microphoneGain), softness: Float(microphoneSoftness)) } }

    let camera = CameraCapture()
    private let microphone = MicrophoneCapture()

    init() {
        refreshDevices()
        microphone.onLevel = { [weak self] level in
            Task { @MainActor in self?.microphoneLevel = CGFloat(level) }
        }
        camera.onFrame = { [weak self] frame in
            Task { @MainActor in self?.cameraFrame = frame }
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
        cameraFrame = nil

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

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.masker.camera")
    private let sampleQueue = DispatchQueue(label: "com.masker.camera.samples")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext()
    private var activeDeviceID: String?
    private var brightness: Float = 0
    private var contrast: Float = 1
    private var whiteBalance: Float = 0
    var onFrame: (@Sendable (CGImage) -> Void)?

    func configure(brightness: Float, contrast: Float, whiteBalance: Float) {
        queue.async { [self] in
            self.brightness = CameraAdjustment.brightnessFilterValue(for: brightness)
            self.contrast = CameraAdjustment.contrastFilterValue(for: contrast)
            self.whiteBalance = min(max(whiteBalance, -1), 1)
        }
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
                        if !session.outputs.contains(where: { $0 === videoOutput }) {
                            videoOutput.alwaysDiscardsLateVideoFrames = true
                            videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
                            guard session.canAddOutput(videoOutput) else {
                                session.commitConfiguration()
                                continuation.resume(returning: "Unable to read video from this camera.")
                                return
                            }
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

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let colorAdjusted = image.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: brightness,
            kCIInputContrastKey: contrast
        ])
        let targetTemperature = 6_500 + whiteBalance * 2_500
        let filtered = colorAdjusted.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6_500, y: 0),
            "inputTargetNeutral": CIVector(x: CGFloat(targetTemperature), y: 0)
        ])
        guard let frame = ciContext.createCGImage(filtered, from: filtered.extent) else { return }
        onFrame?(frame)
    }
}

final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.masker.microphone")
    private let sampleQueue = DispatchQueue(label: "com.masker.microphone.samples")
    private let audioOutput = AVCaptureAudioDataOutput()
    private var activeDeviceID: String?
    private var gain: Float = 1
    private var softness: Float = 0
    private var previousLevel: Float = 0
    var onLevel: (@Sendable (Float) -> Void)?

    func configure(gain: Float, softness: Float) {
        queue.async { [self] in
            self.gain = min(max(gain, 0), 2)
            self.softness = min(max(softness, 0), 0.95)
        }
    }

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
            previousLevel = 0
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
        if let peak {
            let adjusted = MicrophoneLevel.adjusted(peak, gain: gain, softness: softness, previous: previousLevel)
            previousLevel = adjusted
            onLevel?(adjusted)
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let frame: CGImage?

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.contents = frame
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.layer?.contents = frame
    }
}

final class PreviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
