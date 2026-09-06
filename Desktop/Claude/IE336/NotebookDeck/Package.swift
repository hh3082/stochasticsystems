// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotebookDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotebookDeck",
            path: "Sources/NotebookDeck",
            linkerSettings: [
                .linkedFramework("WebKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Quartz"),
            ]
        )
    ]
)
