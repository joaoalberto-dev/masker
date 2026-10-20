import CoreImage
import CoreMedia
import CoreMediaIO
import Foundation
import ImageIO
import IOKit.audio
import Security

private let cameraFrameRate: Int32 = 30
private let cameraWidth = 1280
private let cameraHeight = 720
private let cameraDeviceID = UUID(uuidString: "7D686D98-9B95-4B42-BBC4-39CFA35B6881")!
private let cameraStreamID = UUID(uuidString: "B4C05171-3918-4A58-8DF9-EC4144B86E42")!

private let publishedFrameURL: URL? = {
    guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault),
          let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
          let group = groups.first,
          let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
    return container.appendingPathComponent("published-camera.jpg")
}()

final class MaskerCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: MaskerCameraStreamSource!
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.masker.camera-extension.frames", qos: .userInteractive)
    private let ciContext = CIContext()
    private var formatDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!

    override init() {
        super.init()
        device = CMIOExtensionDevice(
            localizedName: "Masker Camera",
            deviceID: cameraDeviceID,
            legacyDeviceID: nil,
            source: self
        )

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(cameraWidth),
            height: Int32(cameraHeight),
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        let attributes: NSDictionary = [
            kCVPixelBufferWidthKey: cameraWidth,
            kCVPixelBufferHeightKey: cameraHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &bufferPool)

        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: formatDescription,
            maxFrameDuration: CMTime(value: 1, timescale: cameraFrameRate),
            minFrameDuration: CMTime(value: 1, timescale: cameraFrameRate),
            validFrameDurations: nil
        )
        streamSource = MaskerCameraStreamSource(streamFormat: streamFormat, device: device)
        try? device.addStream(streamSource.stream)
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = "Masker Filtered Camera" }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func startStreaming() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / cameraFrameRate)))
        timer.setEventHandler { [weak self] in self?.sendFrame() }
        self.timer = timer
        timer.resume()
    }

    func stopStreaming() {
        timer?.cancel()
        timer = nil
    }

    private func sendFrame() {
        guard let bufferPool, let formatDescription else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return }

        if let url = publishedFrameURL,
           let data = try? Data(contentsOf: url),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let ciImage = CIImage(cgImage: image)
            let scaleX = CGFloat(cameraWidth) / ciImage.extent.width
            let scaleY = CGFloat(cameraHeight) / ciImage.extent.height
            let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            ciContext.render(
                scaled,
                to: pixelBuffer,
                bounds: CGRect(x: 0, y: 0, width: CGFloat(cameraWidth), height: CGFloat(cameraHeight)),
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        } else {
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, 0, CVPixelBufferGetBytesPerRow(pixelBuffer) * cameraHeight)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: cameraFrameRate),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }
        streamSource.stream.send(
            sampleBuffer,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * 1_000_000_000)
        )
    }
}

final class MaskerCameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let streamFormat: CMIOExtensionStreamFormat
    private weak var device: CMIOExtensionDevice?

    init(streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.streamFormat = streamFormat
        self.device = device
        super.init()
        stream = CMIOExtensionStream(
            localizedName: "Masker Camera Video",
            streamID: cameraStreamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }
    var activeFormatIndex: Int = 0
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = activeFormatIndex }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: cameraFrameRate) }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex { activeFormatIndex = index }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        (device?.source as? MaskerCameraDeviceSource)?.startStreaming()
    }

    func stopStream() throws {
        (device?.source as? MaskerCameraDeviceSource)?.stopStreaming()
    }
}

final class MaskerCameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private let deviceSource = MaskerCameraDeviceSource()

    override init() {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: nil)
        try? provider.addDevice(deviceSource.device)
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}
    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "Masker" }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
