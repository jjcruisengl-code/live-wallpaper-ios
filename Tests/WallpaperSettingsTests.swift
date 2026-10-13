import XCTest
@testable import LiveWallpaper

final class WallpaperSettingsTests: XCTestCase {
    func testShortSourceUsesAllAvailableVideo() {
        var settings = WallpaperSettings()
        settings.startSeconds = 4
        settings.normalize(for: 0.2)
        XCTAssertEqual(settings.startSeconds, 0)
        XCTAssertEqual(settings.durationSeconds, 0.2)
    }

    func testSelectionIsMovedInsideTheEndOfTheVideo() {
        var settings = WallpaperSettings()
        settings.startSeconds = 9.5
        settings.durationSeconds = 2
        settings.normalize(for: 10)
        XCTAssertEqual(settings.startSeconds, 8)
        XCTAssertEqual(settings.durationSeconds, 2)
    }

    func testClipDurationIsBounded() {
        var settings = WallpaperSettings()
        settings.durationSeconds = 100
        settings.normalize(for: 20)
        XCTAssertEqual(settings.durationSeconds, WallpaperSettings.maximumClipDuration)

        settings.durationSeconds = -1
        settings.startSeconds = -10
        settings.normalize(for: 20)
        XCTAssertEqual(settings.durationSeconds, WallpaperSettings.minimumClipDuration)
        XCTAssertEqual(settings.startSeconds, 0)
    }

    func testSelectionCannotExceedWholeSource() {
        var settings = WallpaperSettings()
        settings.durationSeconds = 3
        settings.startSeconds = 1
        settings.normalize(for: 2)
        XCTAssertEqual(settings.startSeconds, 0)
        XCTAssertEqual(settings.durationSeconds, 2)
    }

    func testInvalidSourceResetsSelectionWithoutChangingSoundChoices() {
        for invalidDuration in [Double.nan, .infinity, -.infinity, 0, -1] {
            var settings = WallpaperSettings()
            settings.previewSoundEnabled = true
            settings.includeAudio = true
            settings.startSeconds = 5
            settings.normalize(for: invalidDuration)
            XCTAssertEqual(settings.startSeconds, 0)
            XCTAssertEqual(settings.durationSeconds, 0)
            XCTAssertTrue(settings.previewSoundEnabled)
            XCTAssertTrue(settings.includeAudio)
        }
    }

    func testNonFiniteSelectionFallsBackToDefaultDurationAndStart() {
        for invalidValue in [Double.nan, .infinity, -.infinity] {
            var settings = WallpaperSettings()
            settings.startSeconds = invalidValue
            settings.durationSeconds = invalidValue
            settings.normalize(for: 10)
            XCTAssertEqual(settings.startSeconds, 0)
            XCTAssertEqual(settings.durationSeconds, 3)
        }
    }

    func testValidSelectionAndSoundChoicesArePreserved() {
        var settings = WallpaperSettings()
        settings.startSeconds = 1.2
        settings.durationSeconds = 1.5
        settings.previewSoundEnabled = true
        settings.includeAudio = false
        let before = settings
        settings.normalize(for: 12)
        XCTAssertEqual(settings, before)
    }
}
