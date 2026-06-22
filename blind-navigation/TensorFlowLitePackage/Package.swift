// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "TensorFlowLitePackage",
    platforms: [.iOS(.v12)],
    products: [
        .library(name: "TensorFlowLite", targets: ["TensorFlowLite"])
    ],
    targets: [
        .binaryTarget(
            name: "TensorFlowLiteC",
            url: "https://github.com/readdle/tensorflow-lite-swift/releases/download/2.17.0/TensorFlowLiteC-2.17.0.xcframework.zip",
            checksum: "73b4542fc7df5563ee0e177d0bf1806381eee0b32dac7736c868958cb74ae249"
        ),
        .target(name: "TensorFlowLite", dependencies: ["TensorFlowLiteC"])
    ]
)
