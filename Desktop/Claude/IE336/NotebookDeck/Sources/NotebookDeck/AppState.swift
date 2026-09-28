import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import PDFKit

enum PaneLayout: String, CaseIterable, Identifiable {
    case sideBySide, stacked
    var id: String { rawValue }
    var label: String { self == .sideBySide ? "Side by Side" : "Stacked" }
}

/// Thin handles the SwiftUI layer and menu commands use to poke the AppKit views.
final class WebController {
    weak var webView: WKWebView?
    func reload() { webView?.reload() }
    func goBack() { webView?.goBack() }
}

final class PDFController: ObservableObject {
    weak var pdfView: PDFView?
    @Published var pageIndex = 0
    @Published var pageCount = 0

    func next() { pdfView?.goToNextPage(nil) }
    func previous() { pdfView?.goToPreviousPage(nil) }
    func first() { pdfView?.goToFirstPage(nil) }
    func last() { pdfView?.goToLastPage(nil) }
    func go(to index: Int) {
        guard let v = pdfView, let doc = v.document, index >= 0, index < doc.pageCount,
              let page = doc.page(at: index) else { return }
        v.go(to: page)
    }
    func refresh() {
        guard let v = pdfView, let doc = v.document else { pageIndex = 0; pageCount = 0; return }
        pageCount = doc.pageCount
        if let p = v.currentPage { pageIndex = doc.index(for: p) }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var notebookURL: URL?          // what the web pane shows
    @Published var notebookFile: URL?         // the .ipynb / .html on disk, if any
    @Published var deckURL: URL?              // pdf / pptx / key
    @Published var layout: PaneLayout { didSet { defaults.set(layout.rawValue, forKey: "layout") } }
    @Published var swapped: Bool { didSet { defaults.set(swapped, forKey: "swapped") } }
    @Published var showToolbars = true
    @Published var continuousSlides = false
    @Published var serverStatus = "No Jupyter server"
    @Published var ollamaStatus = ""
    @Published var depsStatus = ""
    private(set) var depsReport: JupyterServer.DependencyReport?
    @Published var busy = false
    @Published var errorMessage: String?
    /// Set once the Models window has been opened at launch, so reopening the main window does not open it again.
    var modelsWindowShownAtLaunch = false

    let web = WebController()
    let pdf = PDFController()
    let server = JupyterServer()
    let ollama = OllamaServer()
    lazy var modelManager: ModelManager = {
        let mm = ModelManager(server: ollama)
        mm.onStatus = { [weak self] in self?.setOllamaStatus($0) }
        return mm
    }()
    private let defaults = UserDefaults.standard

    private init() {
        layout = PaneLayout(rawValue: defaults.string(forKey: "layout") ?? "") ?? .sideBySide
        swapped = defaults.bool(forKey: "swapped")
    }

    // MARK: Session restore

    private var restored = false
    func restoreLastSession() {
        guard !restored else { return }
        restored = true
        AppLog.write("restoreLastSession (deck=\(deckURL?.path ?? "nil"), notebook=\(notebookFile?.path ?? "nil"))")
        if deckURL == nil, let p = defaults.string(forKey: "deckFile"), FileManager.default.fileExists(atPath: p) {
            deckURL = URL(fileURLWithPath: p)
        }
        BundledRuntime.migrateNotebooksFolder()
        ensureOllama()
        checkDependencies()
        guard notebookFile == nil, notebookURL == nil else { return }
        if let saved = defaults.string(forKey: "notebookFile"),
           case let p = BundledRuntime.remapLegacyPath(saved), FileManager.default.fileExists(atPath: p) {
            openNotebook(file: URL(fileURLWithPath: p))
        } else if let s = defaults.string(forKey: "notebookURL"), let u = URL(string: s) {
            notebookURL = u
        } else {
            openWorkspace()
        }
    }

    /// Starts JupyterLab on the notebooks folder and shows its file browser, so the app is
    /// ready to work the moment it opens even before a notebook is chosen.
    func openWorkspace() {
        let dir: URL
        do { dir = try BundledRuntime.installNotebooks(overwrite: false) } catch {
            errorMessage = "Could not prepare the notebooks folder: \(error.localizedDescription)"; return
        }
        notebookFile = nil
        defaults.removeObject(forKey: "notebookFile")
        defaults.removeObject(forKey: "notebookURL")
        Task { await launch(root: dir, open: nil, restart: false) }
    }

    /// Imports every required package in the bundled Python, off the main thread.
    func checkDependencies() {
        depsStatus = "Checking Python…"
        Task {
            let report = await Task.detached { JupyterServer.checkDependencies() }.value
            depsReport = report
            depsStatus = report.summary
            if !report.ok { errorMessage = "The Python environment is incomplete.\n\nMissing: \(report.missing.joined(separator: ", "))\n\nSee File > Show App Log." }
        }
    }

    func showEnvironment() {
        let r = depsReport
        let alert = NSAlert()
        alert.messageText = "Python environment"
        var lines = ["Launcher: \(JupyterServer.resolveLauncher().map { "\($0.exe.path) [\($0.label)]" } ?? "none found")", ""]
        if let r {
            lines += JupyterServer.requiredModules.map { m in "\(m): \(r.versions[m] ?? "MISSING")" }
        } else {
            lines.append("Check still running.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Full Audit…")
        if alert.runModal() == .alertSecondButtonReturn { runFullAudit() }
    }

    /// Imports every installed package under an isolated interpreter (takes ~20 s).
    func runFullAudit() {
        busy = true
        depsStatus = "Auditing every package…"
        Task {
            let text = await Task.detached { JupyterServer.fullAudit() }.value
            busy = false
            depsStatus = depsReport?.summary ?? ""
            let alert = NSAlert()
            alert.messageText = "Bundled runtime audit"
            alert.informativeText = text
            alert.runModal()
        }
    }

    func shutdown() { server.stop(); ollama.stop() }

    // MARK: Bundled notebooks

    var bundledNotebookNames: [String] { BundledRuntime.bundledNotebookNames }

    func openBundledNotebook(named name: String) {
        do {
            let dir = try BundledRuntime.installNotebooks(overwrite: false)
            openNotebook(file: dir.appendingPathComponent(name))
        } catch {
            errorMessage = "Could not copy the bundled notebooks: \(error.localizedDescription)"
        }
    }

    func resetBundledNotebooks() {
        let alert = NSAlert()
        alert.messageText = "Replace your copies of the bundled notebooks?"
        alert.informativeText = "Every notebook in \(BundledRuntime.userNotebooksDir.path) that shipped with the app is overwritten with the original. Your edits to those files are lost; other files in the folder are untouched."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try BundledRuntime.installNotebooks(overwrite: true)
            if let f = notebookFile, f.path.hasPrefix(BundledRuntime.userNotebooksDir.path) { web.reload() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealNotebooksFolder() {
        try? BundledRuntime.installNotebooks(overwrite: false)
        NSWorkspace.shared.activateFileViewerSelecting([BundledRuntime.userNotebooksDir])
    }

    func ensureOllama() {
        Task {
            ollamaStatus = "Ollama: starting…"
            setOllamaStatus(await ollama.status())
        }
    }

    private var loggedOllamaStatus = ""
    /// Shows `s` in the toolbar and logs it when it differs from the last status logged.
    private func setOllamaStatus(_ s: String) {
        ollamaStatus = s
        if s != loggedOllamaStatus {
            loggedOllamaStatus = s
            AppLog.write("ollama: status: \(s)")
        }
    }

    func restartOllama() {
        ollama.stop()
        ensureOllama()
    }

    // MARK: Opening things

    static let notebookTypes: [UTType] = [UTType(filenameExtension: "ipynb") ?? .json, .html]
    static let deckTypes: [UTType] = [.pdf, UTType(filenameExtension: "pptx"), UTType(filenameExtension: "key"),
                                      UTType(filenameExtension: "ppt")].compactMap { $0 }

    /// Route a dropped or Finder-opened file to the right pane.
    func open(url: URL) {
        AppLog.write("open: \(url.path)")
        switch url.pathExtension.lowercased() {
        case "ipynb", "html", "htm": openNotebook(file: url)
        case "pdf", "pptx", "ppt", "key": openDeck(file: url)
        default: errorMessage = "Unsupported file: \(url.lastPathComponent)"
        }
    }

    func openDeck(file: URL) {
        deckURL = file
        defaults.set(file.path, forKey: "deckFile")
    }

    func openNotebook(file: URL) {
        notebookFile = file
        defaults.set(file.path, forKey: "notebookFile")
        defaults.removeObject(forKey: "notebookURL")

        if ["html", "htm"].contains(file.pathExtension.lowercased()) {
            notebookURL = file
            return
        }
        ensureOllama()
        Task { await launch(for: file, restart: false) }
    }

    func restartServer() {
        if let f = notebookFile, f.pathExtension.lowercased() == "ipynb" {
            Task { await launch(for: f, restart: true) }
        } else if let root = server.rootDir {
            Task { await launch(root: root, open: nil, restart: true) }
        } else {
            openWorkspace()
        }
    }

    private var launching: URL?
    private func launch(for file: URL, restart: Bool) async {
        await launch(root: file.deletingLastPathComponent(), open: file, restart: restart)
    }

    /// Starts (or reuses) the server rooted at `root` and shows `open`, or the file browser.
    private func launch(root: URL, open file: URL?, restart: Bool) async {
        let key = file ?? root
        if !restart, server.isRunning, server.rootDir?.path == root.path || (file.map { server.serves($0) } ?? false) {
            notebookURL = file.map { server.url(for: $0) } ?? server.labURL
            return
        }
        if !restart, launching == key { return }   // already starting for this
        launching = key
        defer { launching = nil }
        busy = true
        serverStatus = "Starting Jupyter…"
        defer { busy = false }
        do {
            _ = try await server.start(rootDir: root)
            notebookURL = file.map { server.url(for: $0) } ?? server.labURL
            let kind: String
            switch server.frontend {
            case .lab: kind = "JupyterLab"
            case .notebook7, .notebook6: kind = "Jupyter Notebook"
            }
            serverStatus = "\(kind) (\(server.label)) on port \(server.port)"
        } catch {
            serverStatus = "Server failed"
            errorMessage = error.localizedDescription
        }
    }

    /// Point the web pane at an arbitrary URL (an already-running server, JupyterHub, nbviewer…).
    func loadNotebookURL(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.contains("://") { s = "http://" + s }
        guard let u = URL(string: s) else { errorMessage = "Not a valid URL: \(string)"; return }
        notebookFile = nil
        defaults.removeObject(forKey: "notebookFile")
        defaults.set(u.absoluteString, forKey: "notebookURL")
        notebookURL = u
    }

    // MARK: Panels

    func chooseNotebook() {
        let panel = NSOpenPanel()
        panel.title = "Open Notebook"
        panel.allowedContentTypes = Self.notebookTypes
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let u = panel.url { openNotebook(file: u) }
    }

    func chooseDeck() {
        let panel = NSOpenPanel()
        panel.title = "Open Slides or PDF"
        panel.allowedContentTypes = Self.deckTypes
        if panel.runModal() == .OK, let u = panel.url { openDeck(file: u) }
    }

    func promptForURL() {
        let alert = NSAlert()
        alert.messageText = "Load Notebook URL"
        alert.informativeText = "Address of a running Jupyter server, JupyterHub, or any web page."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.stringValue = notebookURL?.absoluteString ?? "http://localhost:8888/"
        alert.accessoryView = field
        alert.addButton(withTitle: "Load")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { loadNotebookURL(field.stringValue) }
    }

    func chooseJupyterExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose the jupyter executable"
        panel.showsHiddenFiles = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        if let cur = JupyterServer.findJupyter() { panel.directoryURL = cur.deletingLastPathComponent() }
        if panel.runModal() == .OK, let u = panel.url {
            defaults.set(u.path, forKey: "jupyterPath")
            serverStatus = "Using \(u.path)"
        }
    }

    func promptForPage() {
        guard pdf.pageCount > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Slide"
        alert.informativeText = "1 – \(pdf.pageCount)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = "\(pdf.pageIndex + 1)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn, let n = Int(field.stringValue) { pdf.go(to: n - 1) }
    }

    func showLog() { NSWorkspace.shared.open(JupyterServer.logURL) }
    func showOllamaLog() { NSWorkspace.shared.open(OllamaServer.logURL) }

    func togglePresentation() {
        showToolbars.toggle()
        if let w = NSApp.keyWindow ?? NSApp.windows.first {
            let isFull = w.styleMask.contains(.fullScreen)
            if showToolbars == isFull { w.toggleFullScreen(nil) }
        }
    }
}
