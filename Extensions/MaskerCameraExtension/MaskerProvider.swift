import AVFoundation
import CoreImage
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio

private let appGroup = "group.com.masker.app"
private let virtualCameraName = "Masker Virtual Camera"
private let targetWidth = 1280
private let targetHeight = 720
private let targetFrameRate: Int32 = 30

final class MaskerDeviceSource: NSObject, CMIOExtensionDeviceSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: MaskerStreamSource!
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private let captureQueue = DispatchQueue(label: "com.masker.camera-extension.capture")
    private let sampleQueue = DispatchQueue(label: "com.masker.camera-extension.samples")
    private let context = CIContext()
    private var destinationPool: CVPixelBufferPool?
    private var outputDescription: CMVideoFormatDescription?
    private var streamingClients = 0

    override init() {
        super.init()
        device = CMIOExtensionDevice(
            localizedName: virtualCameraName,
            deviceID: UUID(uuidString: "CC0D9141-8596-4E1F-9E50-8820A917C1F9")!,
            legacyDeviceID: nil,
            source: self
        )
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(targetWidth),
            height: Int32(targetHeight),
            extensions: nil,
            formatDescriptionOut: &outputDescription
        )
        guard status == noErr, let outputDescription else {
            fatalError("Unable to create the virtual camera format: \(status)")
        }
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: targetWidth,
            kCVPixelBufferHeightKey as String: targetHeight,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes as CFDictionary, &destinationPool)

        let frameDuration = CMTime(value: 1, timescale: targetFrameRate)
        let format = CMIOExtensionStreamFormat(
            formatDescription: outputDescription,
            maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration,
            validFrameDurations: [frameDuration]
        )
        streamSource = MaskerStreamSource(
            localizedName: virtualCameraName,
            streamID: UUID(uuidString: "8F40BD2B-4AE8-4BE3-8DD2-254E35B5A0B2")!,
            format: format,
            deviceSource: self
        )
        do {
            try device.addStream(streamSource.stream)
        } catch {
            fatalError("Unable to add the virtual camera stream: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceModel, .deviceTransportType] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceModel) { result.model = "Masker Filter Camera" }
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws { }

    func startStreaming() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.streamingClients += 1
            guard self.streamingClients == 1 else { return }
            self.configureAndStartCapture()
        }
    }

    func stopStreaming() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.streamingClients = max(0, self.streamingClients - 1)
            guard self.streamingClients == 0 else { return }
            self.session?.stopRunning()
            self.session = nil
            self.output = nil
        }
    }

    private func configureAndStartCapture() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        let physicalCameras = discovery.devices.filter { $0.localizedName != virtualCameraName }
        let preferredID = UserDefaults(suiteName: appGroup)?.string(forKey: "virtualCamera.sourceDeviceID")
        let camera = preferredID.flatMap { id in physicalCameras.first { $0.uniqueID == id } }
            ?? physicalCameras.first
        guard let camera, let input = try? AVCaptureDeviceInput(device: camera) else { return }

        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720
        guard captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(input)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        guard captureSession.canAddOutput(videoOutput) else {
            captureSession.commitConfiguration()
            return
        }
        captureSession.addOutput(videoOutput)
        captureSession.commitConfiguration()
        output = videoOutput
        session = captureSession
        captureSession.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let destinationPool,
              let outputDescription else { return }
        var destinationBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, destinationPool, &destinationBuffer) == kCVReturnSuccess,
              let destinationBuffer else { return }

        let defaults = UserDefaults(suiteName: appGroup)
        let brightness = defaults?.double(forKey: "virtualCamera.brightness") ?? 0
        let contrast = defaults?.double(forKey: "virtualCamera.contrast") ?? 1
        let whiteBalance = defaults?.double(forKey: "virtualCamera.whiteBalance") ?? 0
        var image = CIImage(cvPixelBuffer: sourceBuffer).applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: brightness,
            kCIInputContrastKey: contrast
        ])
        image = image.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6_500, y: 0),
            "inputTargetNeutral": CIVector(x: 6_500 + whiteBalance * 2_500, y: 0)
        ])
        let bounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        let scale = max(bounds.width / image.extent.width, bounds.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let cropOrigin = CGPoint(x: image.extent.midX - bounds.width / 2, y: image.extent.midY - bounds.height / 2)
        image = image.cropped(to: CGRect(origin: cropOrigin, size: bounds.size)).transformed(
            by: CGAffineTransform(translationX: -cropOrigin.x, y: -cropOrigin.y)
        )
        context.render(image, to: destinationBuffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: targetFrameRate),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: .invalid
        )
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: destinationBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: outputDescription,
            sampleTiming: &timing,
            sampleBufferOut: &result
        ) == noErr, let result else { return }

        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        let nanoseconds = CMTimeConvertScale(hostTime, timescale: 1_000_000_000, method: .default).value
        streamSource.stream.send(result, discontinuity: [], hostTimeInNanoseconds: UInt64(max(0, nanoseconds)))
    }
}

private final class MaskerStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private let deviceSource: MaskerDeviceSource

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, deviceSource: MaskerDeviceSource) {
        self.format = format
        self.deviceSource = deviceSource
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: targetFrameRate) }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws { }
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }
    func startStream() throws { deviceSource.startStreaming() }
    func stopStream() throws { deviceSource.stopStreaming() }
}

final class MaskerProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: MaskerDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = MaskerDeviceSource()
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Unable to publish the virtual camera: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws { }
    func disconnect(from client: CMIOExtensionClient) { }
    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "Masker" }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws { }
}
