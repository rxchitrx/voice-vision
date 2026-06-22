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
            url: "https://github.com/readdle/tensorflow-lite-swift/releases/download/2.16.1/TensorFlowLiteC-2.16.1.xcframework.zip",
            checksum: "c3d00a89a97999510ce9acee5063a847dc9b6fbf3353ae97d50bb8f94270a6bf"
        ),
        .target(name: "TensorFlowLite", dependencies: ["TensorFlowLiteC"])
    ]
)
