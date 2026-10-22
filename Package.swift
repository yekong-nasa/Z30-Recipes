// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Z30LabCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "Z30LabCore", targets: ["Z30LabCore"])],
    targets: [
        .target(name: "Z30LabCore", path: "Sources/Core"),
        .testTarget(name: "CoreTests", dependencies: ["Z30LabCore"], path: "Tests/CoreTests",
                    resources: [.copy("mono-curve.NCP"), .copy("neutral-export.NP3"), .copy("neutral-payload.bin"), .copy("neutral-state-zero.NCP"), .copy("neutral-curve.NCP"), .copy("deviceinfo.bin"), .copy("photo-control-desc.bin"), .copy("current-picture-control.bin"), .copy("standard.bin"), .copy("standard.NP3"), .copy("parameter-map.NP3"), .copy("parameter-map.bin")])
    ]
)
