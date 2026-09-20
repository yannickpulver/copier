import Foundation
import ProjectDescription

// MARK: - Version

/// `MARKETING_VERSION` comes from the repo-root `VERSION` file (the file the release
/// workflow reads), overridable with `TUIST_COPIER_VERSION`.
let marketingVersion: String = {
    let override = Environment.copierVersion.getString(default: "")
    if !override.isEmpty { return override }
    let manifestDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let versionFile = manifestDirectory.deletingLastPathComponent().appendingPathComponent("VERSION")
    let contents = (try? String(contentsOf: versionFile, encoding: .utf8)) ?? ""
    let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "0.0.0" : trimmed
}()

/// `CURRENT_PROJECT_VERSION`, overridable with `TUIST_COPIER_BUILD`.
let buildVersion: String = {
    let override = Environment.copierBuild.getString(default: "")
    return override.isEmpty ? "1" : override
}()

// MARK: - Settings

let sharedSettings: SettingsDictionary = [
    "MARKETING_VERSION": .string(marketingVersion),
    "CURRENT_PROJECT_VERSION": .string(buildVersion),
    "SWIFT_VERSION": "6.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "MACOSX_DEPLOYMENT_TARGET": "26.0",
    "DEAD_CODE_STRIPPING": "YES",
]

let appSettings: SettingsDictionary = sharedSettings.merging([
    // Notarization needs the hardened runtime; the app walks arbitrary volumes, so no sandbox.
    "ENABLE_HARDENED_RUNTIME": "YES",
    "ENABLE_APP_SANDBOX": "NO",
    // "Sign to Run Locally" — ad-hoc, no team required for a local build.
    "CODE_SIGN_IDENTITY": "-",
    "CODE_SIGN_STYLE": "Manual",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "COMBINE_HIDPI_IMAGES": "YES",
]) { _, new in new }

// MARK: - Project

let project = Project(
    name: "Copier",
    organizationName: "Yannick Pulver",
    packages: [
        .local(path: "CopierCore"),
    ],
    settings: .settings(base: sharedSettings),
    targets: [
        .target(
            name: "Copier",
            destinations: [.mac],
            product: .app,
            bundleId: "com.yannickpulver.copier",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Copier",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "LSApplicationCategoryType": "public.app-category.photography",
                "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
                "NSHumanReadableCopyright": "© Yannick Pulver",
                "NSRemovableVolumesUsageDescription":
                    "Copier reads the photos and videos on your memory cards so it can back them up.",
                "NSNetworkVolumesUsageDescription":
                    "Copier reads and writes your NAS shares to check for existing backups and to copy files there.",
                "NSDesktopFolderUsageDescription":
                    "Copier needs access when you back up to, or check, a folder on your Desktop.",
                "NSDocumentsFolderUsageDescription":
                    "Copier needs access when you back up to, or check, a folder in your Documents.",
                "NSDownloadsFolderUsageDescription":
                    "Copier needs access when you back up to, or check, a folder in your Downloads.",
            ]),
            sources: ["Copier/Sources/**"],
            resources: ["Copier/Resources/**"],
            dependencies: [
                .package(product: "CopierCore"),
            ],
            settings: .settings(base: appSettings)
        ),
        .target(
            name: "CopierTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "com.yannickpulver.copier.tests",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .default,
            // The model layer is compiled straight into the test bundle, so the tests
            // need no host application and never launch the UI.
            sources: ["Copier/Tests/**", "Copier/Sources/Model/**"],
            dependencies: [
                .package(product: "CopierCore"),
            ],
            settings: .settings(base: sharedSettings)
        ),
    ],
    schemes: [
        .scheme(
            name: "Copier",
            shared: true,
            buildAction: .buildAction(targets: ["Copier", "CopierTests"]),
            testAction: .targets(["CopierTests"]),
            runAction: .runAction(executable: "Copier")
        ),
    ]
)
