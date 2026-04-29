import Foundation
import XCTest

final class BuildConfigConsistencyTests: XCTestCase {
    func testCloudImagesScreenSaverModuleSourcesAreDeclaredInSwiftPMAndXcode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageSwift = try String(contentsOf: root.appendingPathComponent("Package.swift"))
        let pbxproj = try String(contentsOf: root.appendingPathComponent("CloudImagesScreenSaver.xcodeproj/project.pbxproj"))

        let expectedModuleSources = [
            "CloudImagesScreenSaverView.swift",
            "ConfigureSheetController.swift",
            "ConfigureSheetAuth.swift",
            "ConfigureSheetViewFactory.swift",
            "SettingsFormModel.swift",
            "ScreenSaverSettings.swift",
            "DropboxScreenSaverOAuth.swift",
        ]

        for source in expectedModuleSources {
            XCTAssertTrue(
                packageSwift.contains("\"\(source)\""),
                "Package.swift の CloudImagesScreenSaverModule sources に \(source) がありません"
            )
            XCTAssertTrue(
                pbxproj.contains("/* \(source) in Sources */"),
                "project.pbxproj の Sources に \(source) がありません"
            )
        }
    }
}
