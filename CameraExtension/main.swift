import CoreMediaIO
import Foundation

let source = MaskerCameraProviderSource()
CMIOExtensionProvider.startService(provider: source.provider)
CFRunLoopRun()
