// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "MessagesForAIMenu",
  // macOS 14 (Sonoma) required for SwiftUI dismissWindow environment
  // and the modern Window scene APIs. Released Sept 2023 — fine for a
  // v0.3.0 utility shipping in 2026.
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "MessagesForAIMenu", targets: ["MessagesForAIMenu"]),
  ],
  dependencies: [
    // Sparkle auto-update. SPM delivers it as a binary XCFramework artifact; the
    // build scripts copy Sparkle.framework into the hand-assembled .app's
    // Contents/Frameworks and sign it (see scripts/build-release.sh + dev-install.sh).
    // Pinned to the audited minor (exact revision in Package.resolved, which IS
    // committed): Sparkle installs code, so we don't want an unaudited drift. Bump
    // deliberately + re-audit; don't `swift package update` blindly.
    .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMinor(from: "2.9.2")),
  ],
  targets: [
    .executableTarget(
      name: "MessagesForAIMenu",
      dependencies: [
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      path: "Sources/MessagesForAIMenu",
      // dyld must find the embedded Sparkle.framework at runtime. SPM doesn't
      // embed frameworks into a hand-assembled .app, so we add the standard
      // app-bundle rpath; the build scripts place the framework there.
      linkerSettings: [
        .linkedLibrary("sqlite3"),
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
      ]
    ),
    // v0.3.2 reduced-scope test target. Covers the net-new walkthrough
    // verification primitives (HealthChecks) + the settings fields the
    // walkthrough depends on (SettingsStore migration / defaults).
    // WhatsAppDaemonControllerTests + DraftStoreTests are deferred to
    // v0.3.3 per the plan-review (require mocked Process / regression
    // coverage of the DispatchSource directory-watcher lesson).
    .testTarget(
      name: "MessagesForAIMenuTests",
      dependencies: ["MessagesForAIMenu"],
      path: "Tests/MessagesForAIMenuTests"
    ),
  ]
)
