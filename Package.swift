// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CloudImagesScreenSaverSupport",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DropboxAPI", targets: ["DropboxAPI"]),
        .executable(name: "dropbox-api-test", targets: ["DropboxAPITest"]),
    ],
    targets: [
        .target(
            name: "DropboxAPI",
            path: "CloudImagesScreenSaver",
            exclude: [
                "ConfigureSheetController.swift",
                "CloudImagesScreenSaverView.swift",
                "ScreenSaverSettings.swift",
                "Info.plist",
            ],
            sources: [
                "DropboxClient.swift",
                "CloudImagesFolderImageLoader.swift",
            ]
        ),
        .executableTarget(
            name: "DropboxAPITest",
            dependencies: ["DropboxAPI"],
            path: "Tools/DropboxAPITest"
        ),
        .testTarget(
            name: "DropboxAPITests",
            dependencies: ["DropboxAPI"],
            path: "Tests/DropboxAPITests"
        ),
    ]
)
