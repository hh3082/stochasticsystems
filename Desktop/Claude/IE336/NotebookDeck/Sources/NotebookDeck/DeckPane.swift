import SwiftUI
import PDFKit
import Quartz
import UniformTypeIdentifiers

struct PDFKitView: NSViewRepresentable {
    let url: URL
    let continuous: Bool
    let controller: PDFController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displaysPageBreaks = true
        v.backgroundColor = NSColor(white: 0.12, alpha: 1)
        v.pageShadowsEnabled = false
        controller.pdfView = v
        let nc = NotificationCenter.default
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.changed), name: .PDFViewPageChanged, object: v)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.changed), name: .PDFViewDocumentChanged, object: v)
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        let mode: PDFDisplayMode = continuous ? .singlePageContinuous : .singlePage
        if v.displayMode != mode {
            let page = v.currentPage
            v.displayMode = mode
            v.autoScales = true
            if let page { v.go(to: page) }
        }
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            v.document = PDFDocument(url: url)
            AppLog.write("pdf: \(url.lastPathComponent) pages=\(v.document?.pageCount ?? -1)")
            v.autoScales = true
            // Restore the slide we were on last time for this file.
            let key = "page:" + url.path
            let saved = UserDefaults.standard.integer(forKey: key)
            if saved > 0, let doc = v.document, saved < doc.pageCount, let p = doc.page(at: saved) { v.go(to: p) }
            DispatchQueue.main.async { controller.refresh() }
        }
    }

    final class Coordinator: NSObject {
        let controller: PDFController
        var loadedURL: URL?
        init(controller: PDFController) { self.controller = controller }
        @objc func changed(_ n: Notification) {
            controller.refresh()
            if let u = loadedURL { UserDefaults.standard.set(controller.pageIndex, forKey: "page:" + u.path) }
        }
    }
}

/// Quick Look rendering for .pptx / .key decks (no page controls, but it shows them).
struct QuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        v.previewItem = url as NSURL
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }
}

struct DeckPane: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var pdf: PDFController
    @State private var pageText = ""
    @State private var dropTargeted = false

    init() { _pdf = ObservedObject(wrappedValue: AppState.shared.pdf) }

    private var isPDF: Bool { state.deckURL?.pathExtension.lowercased() == "pdf" }

    var body: some View {
        VStack(spacing: 0) {
            if state.showToolbars { toolbar; Divider() }
            ZStack {
                if let u = state.deckURL {
                    if isPDF {
                        PDFKitView(url: u, continuous: state.continuousSlides, controller: state.pdf)
                    } else {
                        QuickLookView(url: u)
                    }
                } else {
                    placeholder
                }
                if dropTargeted { DropHighlight() }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            FileDrop.handle(providers) { AppState.shared.open(url: $0) }
        }
        .onChange(of: pdf.pageIndex) { _, i in pageText = "\(i + 1)" }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { state.chooseDeck() } label: { Label("Open Slides", systemImage: "rectangle.on.rectangle") }
                .help("Open a PDF (page controls) or a .pptx/.key (Quick Look)")
            if isPDF {
                Button { pdf.previous() } label: { Image(systemName: "chevron.left") }.help("Previous slide")
                Button { pdf.next() } label: { Image(systemName: "chevron.right") }.help("Next slide")
                TextField("", text: $pageText)
                    .textFieldStyle(.roundedBorder).frame(width: 44).multilineTextAlignment(.trailing)
                    .onSubmit { if let n = Int(pageText) { pdf.go(to: n - 1) } }
                Text("/ \(pdf.pageCount)").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $state.continuousSlides) {
                    Text("Slide").tag(false)
                    Text("Scroll").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 110)
                .help("One slide at a time, or continuous scrolling")
            }
            Spacer()
            Text(state.deckURL?.lastPathComponent ?? "")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.bar)
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Drop a PDF or slide deck here, or open one").foregroundStyle(.secondary)
            Button("Open Slides…") { state.chooseDeck() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
