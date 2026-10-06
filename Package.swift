// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "call-recorder",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Diarization locale (CoreML) — modèles pré-téléchargés et embarqués,
        // aucune connexion réseau à l'exécution (voir scripts/download-models.sh)
        // Épinglé sur la révision testée pour des builds reproductibles d'un Mac à l'autre
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "162e6918ef500fe5f99eebdb1b442cf772713afb")
    ],
    targets: [
        .target(
            name: "CallRecorderKit",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/CallRecorderKit"
        ),
        .executableTarget(
            name: "call-recorder",
            dependencies: ["CallRecorderKit"],
            path: "Sources/call-recorder",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "CallRecorderMenuBar",
            dependencies: ["CallRecorderKit"],
            path: "Sources/CallRecorderMenuBar",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "MenuBarInfo.plist"
                ])
            ]
        )
    ]
)
