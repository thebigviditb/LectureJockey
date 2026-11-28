// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LectureJockey",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "lecturejockey", targets: ["lecturejockey"]),
    ],
    targets: [
        .target(
            name: "LectureJockeyCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "lecturejockey",
            dependencies: ["LectureJockeyCore"]
        ),
        .testTarget(
            name: "LectureJockeyCoreTests",
            dependencies: ["LectureJockeyCore"]
        ),
    ]
)
