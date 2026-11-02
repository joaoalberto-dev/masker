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
final class DeviceBrowserModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var microphones: [AVCaptureDevice] = []
    @Published var selection: DeviceSelection?
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published private(set) var cameraMessage: String?
    @Published private(set) var microphoneMessage: String?
    @Published private(set) var microphoneLevel: CGFloat = 0
    @Published private(set) var isRecording = false
    @Published private(set) var recordingURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var recordingMessage: String?
    @Published private(set) var cameraFrame: CGImage?
    @Published var cameraBrightness: Double = PreviewControlDefaults.cameraBrightness { didSet { camera.configure(brightness: Float(cameraBrightness), contrast: Float(cameraContrast), whiteBalance: Float(cameraWhiteBalance)); VirtualDevicePreferences.set(cameraBrightness, forKey: VirtualDevicePreferences.cameraBrightness) } }
    @Published var cameraContrast: Double = PreviewControlDefaults.cameraContrast { didSet { camera.configure(brightness: Float(cameraBrightness), contrast: Float(cameraContrast), whiteBalance: Float(cameraWhiteBalance)); VirtualDevicePreferences.set(cameraContrast, forKey: VirtualDevicePreferences.cameraContrast) } }
    @Published var cameraWhiteBalance: Double = PreviewControlDefaults.cameraWhiteBalance { didSet { camera.configure(brightness: Float(cameraBrightness), contrast: Float(cameraContrast), whiteBalance: Float(cameraWhiteBalance)); VirtualDevicePreferences.set(cameraWhiteBalance, forKey: VirtualDevicePreferences.cameraWhiteBalance) } }
    @Published var microphoneGain: Double = PreviewControlDefaults.microphoneGain { didSet { microphone.configure(gain: Float(microphoneGain), softness: Float(microphoneSoftness)) } }
    @Published var microphoneSoftness: Double = PreviewControlDefaults.microphoneSoftness { didSet { microphone.configure(gain: Float(microphoneGain), softness: Float(microphoneSoftness)) } }

    let camera = CameraCapture()
    private let microphone = MicrophoneCapture()
    private var audioPlayer: AVAudioPlayer?

    override init() {
        super.init()
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
        ).devices.filter { $0.localizedName != VirtualDevicePreferences.cameraName }
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
        if case .camera(let id) = selection {
            VirtualDevicePreferences.set(id, forKey: VirtualDevicePreferences.cameraDeviceID)
        }
    }

    func stop() {
        stopPlayback()
        if isRecording { stopRecording() }
        camera.stop()
        microphone.stop()
    }

    func startRecording() {
        guard !isRecording else { return }
        stopPlayback()
        recordingMessage = nil
        recordingURL = nil
        recordingDuration = 0
        microphone.startRecording(gain: Float(microphoneGain), softness: Float(microphoneSoftness)) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.isRecording = true
                case .failure(let error):
                    self.recordingMessage = "Unable to record audio: \(error.localizedDescription)"
                }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        microphone.stopRecording { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let url):
                    do {
                        let player = try AVAudioPlayer(contentsOf: url)
                        player.delegate = self
                        self.audioPlayer = player
                        self.recordingURL = url
                        self.recordingDuration = player.duration
                    } catch {
                        self.recordingMessage = "Unable to open the recorded audio: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    self.recordingMessage = "Unable to finish the recording: \(error.localizedDescription)"
                }
            }
        }
    }

    func togglePlayback() {
        guard let audioPlayer else { return }
        if audioPlayer.isPlaying {
            stopPlayback()
        } else if audioPlayer.play() {
            isPlaying = true
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        isPlaying = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
    }

    func select(_ selection: DeviceSelection?) {
        self.selection = selection
        if case .camera(let id) = selection {
            VirtualDevicePreferences.set(id, forKey: VirtualDevicePreferences.cameraDeviceID)
        }
        stopPlayback()
        if isRecording { stopRecording() }
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
    private var recordingHandle: FileHandle?
    private var recordingURL: URL?
    private var recordedByteCount: UInt32 = 0
    private var recordingGain: Float = 1
    private var recordingSoftness: Float = 0
    private var previousSamples = [Float]()
    private let sampleRate: UInt32 = 44_100
    private let channelCount: UInt16 = 1
    var onLevel: (@Sendable (Float) -> Void)?

    func configure(gain: Float, softness: Float) {
        sampleQueue.async { [self] in
            self.gain = min(max(gain, 0), 2)
            self.softness = min(max(softness, 0), 0.95)
            self.recordingGain = self.gain
            self.recordingSoftness = self.softness
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
                    audioOutput.audioSettings = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: sampleRate,
                        AVNumberOfChannelsKey: channelCount,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsNonInterleaved: false
                    ]
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
            sampleQueue.sync { finishRecording(completion: nil) }
            if session.isRunning { session.stopRunning() }
            activeDeviceID = nil
            sampleQueue.async { [self] in
                previousLevel = 0
                onLevel?(0)
            }
        }
    }

    func startRecording(gain: Float, softness: Float, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        sampleQueue.async { [self] in
            do {
                guard recordingHandle == nil else { throw RecordingError.alreadyRecording }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Masker-\(UUID().uuidString).wav")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                handle.write(Data(Self.wavHeader(sampleRate: sampleRate, channels: channelCount, byteCount: 0)))
                self.recordingHandle = handle
                self.recordingURL = url
                self.recordedByteCount = 0
                self.recordingGain = min(max(gain, 0), 2)
                self.recordingSoftness = min(max(softness, 0), 0.95)
                self.previousSamples = Array(repeating: 0, count: Int(channelCount))
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func stopRecording(completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        sampleQueue.async { [self] in
            finishRecording { result in completion(result) }
        }
    }

    private func finishRecording(completion: ((Result<URL, Error>) -> Void)?) {
        guard let handle = recordingHandle, let url = recordingURL else {
            completion?(.failure(RecordingError.noRecording))
            return
        }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Data(Self.wavHeader(sampleRate: sampleRate, channels: channelCount, byteCount: recordedByteCount)))
            try handle.close()
            recordingHandle = nil
            recordingURL = nil
            completion?(.success(url))
        } catch {
            recordingHandle = nil
            recordingURL = nil
            completion?(.failure(error))
        }
    }

    private enum RecordingError: LocalizedError {
        case alreadyRecording
        case noRecording
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: "A recording is already in progress."
            case .noRecording: "There is no recording to finish."
            case .unsupportedFormat: "The microphone provided an unsupported audio format."
            }
        }
    }

    private static func wavHeader(sampleRate: UInt32, channels: UInt16, byteCount: UInt32) -> [UInt8] {
        let data = byteCount
        let riffSize = data &+ 36
        let byteRate = sampleRate &* UInt32(channels) &* 2
        let blockAlign = channels &* 2
        return Array("RIFF".utf8) + littleEndian(riffSize) + Array("WAVEfmt ".utf8) + littleEndian(UInt32(16)) +
            littleEndian(UInt16(1)) + littleEndian(channels) + littleEndian(sampleRate) + littleEndian(byteRate) +
            littleEndian(blockAlign) + littleEndian(UInt16(16)) + Array("data".utf8) + littleEndian(data)
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
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
            let inputSamples = UnsafeBufferPointer(start: samples, count: sampleCount)
            peak = MicrophoneLevel.peak(in: inputSamples)
            if let recordingHandle {
                guard stream.mChannelsPerFrame == channelCount, stream.mSampleRate == Double(sampleRate) else { return }
                var filtered = [Int16]()
                filtered.reserveCapacity(sampleCount)
                let amount = recordingSoftness
                for index in 0..<sampleCount {
                    let channel = index % Int(channelCount)
                    let input = Float(inputSamples[index]) / 32_768
                    let smoothed = input * (1 - amount) + previousSamples[channel] * amount
                    previousSamples[channel] = smoothed
                    let output = min(max(smoothed * recordingGain, -1), 1)
                    filtered.append(Int16((output * 32_767).rounded()))
                }
                let bytes = filtered.withUnsafeBytes { Data($0) }
                do {
                    try recordingHandle.write(contentsOf: bytes)
                    recordedByteCount &+= UInt32(bytes.count)
                } catch {
                    finishRecording(completion: nil)
                }
            }
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
