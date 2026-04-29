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
                "DropboxScreenSaverOAuth.swift",
                "Info.plist",
            ],
            sources: [
                "DropboxClient.swift",
                "DropboxOAuth.swift",
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
        .target(
            name: "CloudImagesScreenSaverModule",
            dependencies: ["DropboxAPI"],
            path: "CloudImagesScreenSaver",
            exclude: [
                "Info.plist",
                "DropboxClient.swift",
                "DropboxOAuth.swift",
                "CloudImagesFolderImageLoader.swift",
            ],
            sources: [
                "CloudImagesScreenSaverView.swift",
                "ConfigureSheetController.swift",
                "ScreenSaverSettings.swift",
                "DropboxScreenSaverOAuth.swift",
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenSaver"),
            ]
        ),
        .testTarget(
            name: "CloudImagesScreenSaverModuleTests",
            dependencies: ["CloudImagesScreenSaverModule", "DropboxAPI"],
            path: "Tests/CloudImagesScreenSaverModuleTests"
        ),
    ]
)
