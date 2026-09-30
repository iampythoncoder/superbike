// swift-tools-version: 5.10
// WARNING: <=5.10 required for GitHub Actions CI
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "UltralyticsYOLO",
  platforms: [
    .iOS(.v13)
  ],
  products: [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
      name: "UltralyticsYOLO",
      targets: ["UltralyticsYOLO"])
  ],
  targets: [
    .target(
      name: "UltralyticsYOLO",
      exclude: ["README.md"]),
  ]
)
