import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct WebView: NSViewRepresentable {
    let url: URL?
    let controller: WebController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        controller.webView = wv
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        guard let url, context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        if url.isFileURL {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            wv.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedURL: URL?

        // target="_blank" links open in the same pane.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = navigationAction.request.url { webView.load(URLRequest(url: u)) }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let a = NSAlert(); a.messageText = message; a.runModal(); completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let a = NSAlert(); a.messageText = message
            a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
            completionHandler(a.runModal() == .alertFirstButtonReturn)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let e = error as NSError
            if e.code == NSURLErrorCancelled { return }
            Task { @MainActor in AppState.shared.errorMessage = e.localizedDescription }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.webView(webView, didFail: navigation, withError: error)
        }
    }
}

struct NotebookPane: View {
    @EnvironmentObject var state: AppState
    @State private var urlText = ""
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if state.showToolbars { toolbar; Divider() }
            ZStack {
                if state.notebookURL != nil {
                    WebView(url: state.notebookURL, controller: state.web)
                } else {
                    placeholder
                }
                if dropTargeted { DropHighlight() }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            FileDrop.handle(providers) { AppState.shared.open(url: $0) }
        }
        .onChange(of: state.notebookURL) { _, new in urlText = new?.absoluteString ?? "" }
        .onAppear { urlText = state.notebookURL?.absoluteString ?? "" }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { state.chooseNotebook() } label: { Label("Open Notebook", systemImage: "doc.text") }
                .help("Open a .ipynb (starts a Jupyter server in its folder) or an exported .html")
            Button { state.web.goBack() } label: { Image(systemName: "chevron.left") }
                .help("Back")
            Button { state.web.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload")
            TextField("Notebook URL", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit { state.loadNotebookURL(urlText) }
            if state.busy { ProgressView().controlSize(.small) }
            Text(state.ollamaStatus.isEmpty ? state.serverStatus : state.serverStatus + "  ·  " + state.ollamaStatus)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.bar)
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Drop a .ipynb here, or open one").foregroundStyle(.secondary)
            HStack {
                Button("Open Notebook…") { state.chooseNotebook() }.keyboardShortcut("o")
                Button("Load URL…") { state.promptForURL() }
                if !state.bundledNotebookNames.isEmpty {
                    Menu("Bundled Notebooks") {
                        ForEach(state.bundledNotebookNames, id: \.self) { name in
                            Button(name) { state.openBundledNotebook(named: name) }
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.08))
            .padding(4)
            .allowsHitTesting(false)
    }
}

enum FileDrop {
    static func handle(_ providers: [NSItemProvider], _ open: @escaping (URL) -> Void) -> Bool {
        guard let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            var url: URL?
            if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            if let url { DispatchQueue.main.async { open(url) } }
        }
        return true
    }
}
