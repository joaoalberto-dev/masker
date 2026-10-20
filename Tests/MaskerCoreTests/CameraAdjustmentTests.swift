import XCTest
@testable import MaskerCore

final class CameraAdjustmentTests: XCTestCase {
    func testPreviewControlDefaultsRestoreNeutralCameraAndMicrophoneValues() {
        XCTAssertEqual(PreviewControlDefaults.cameraBrightness, 0)
        XCTAssertEqual(PreviewControlDefaults.cameraContrast, 1)
        XCTAssertEqual(PreviewControlDefaults.cameraWhiteBalance, 0)
        XCTAssertEqual(PreviewControlDefaults.microphoneGain, 1)
        XCTAssertEqual(PreviewControlDefaults.microphoneSoftness, 0)
    }

    func testContrastMapsOneToOneToCIContrastValue() {
        XCTAssertEqual(CameraAdjustment.contrastFilterValue(for: 1), 1)
        XCTAssertEqual(CameraAdjustment.contrastFilterValue(for: 1.5), 1.5)
    }

    func testBrightnessMapsToCoreImageRange() {
        XCTAssertEqual(CameraAdjustment.brightnessFilterValue(for: -1), -1)
        XCTAssertEqual(CameraAdjustment.brightnessFilterValue(for: 1), 1)
    }
}
