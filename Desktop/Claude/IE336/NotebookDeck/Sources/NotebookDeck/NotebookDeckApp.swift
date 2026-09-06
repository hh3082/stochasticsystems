import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { AppState.shared.open(url: $0) }
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.layout == .sideBySide {
                HSplitView { first; second }
            } else {
                VSplitView { first; second }
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .onAppear { state.restoreLastSession() }
        .alert("NotebookDeck", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    @ViewBuilder private var first: some View {
        if state.swapped { deck } else { notebook }
    }
    @ViewBuilder private var second: some View {
        if state.swapped { notebook } else { deck }
    }
    private var notebook: some View {
        NotebookPane().frame(minWidth: 300, idealWidth: 800, maxWidth: .infinity,
                             minHeight: 200, idealHeight: 500, maxHeight: .infinity)
    }
    private var deck: some View {
        DeckPane().frame(minWidth: 300, idealWidth: 800, maxWidth: .infinity,
                         minHeight: 200, idealHeight: 500, maxHeight: .infinity)
    }
}

@main
struct NotebookDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        Window("NotebookDeck", id: "main") {
            ContentView().environmentObject(state)
        }
        .defaultSize(width: 1600, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Notebook…") { state.chooseNotebook() }.keyboardShortcut("o")
                Button("Open Slides or PDF…") { state.chooseDeck() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Load Notebook URL…") { state.promptForURL() }.keyboardShortcut("l")
                if !state.bundledNotebookNames.isEmpty {
                    Divider()
                    Menu("Bundled Notebooks") {
                        ForEach(state.bundledNotebookNames, id: \.self) { name in
                            Button(name) { state.openBundledNotebook(named: name) }
                        }
                        Divider()
                        Button("Show Notebooks Folder in Finder") { state.revealNotebooksFolder() }
                        Button("Reset Bundled Notebooks…") { state.resetBundledNotebooks() }
                    }
                }
                Divider()
                Button("Reload Notebook") { state.web.reload() }.keyboardShortcut("r")
                Button("Restart Jupyter Server") { state.restartServer() }
                Button("Set Jupyter Executable…") { state.chooseJupyterExecutable() }
                Button("Show Jupyter Log") { state.showLog() }
                Divider()
                Button("Restart Ollama") { state.restartOllama() }
                Button("Show Ollama Log") { state.showOllamaLog() }
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Swap Panes") { state.swapped.toggle() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Picker("Layout", selection: $state.layout) {
                    ForEach(PaneLayout.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show Toolbars", isOn: $state.showToolbars).keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Presentation Mode") { state.togglePresentation() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
            }
            CommandMenu("Slides") {
                Button("Next Slide") { state.pdf.next() }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Previous Slide") { state.pdf.previous() }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("First Slide") { state.pdf.first() }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Last Slide") { state.pdf.last() }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Go to Slide…") { state.promptForPage() }.keyboardShortcut("g")
                Divider()
                Toggle("Continuous Scroll", isOn: $state.continuousSlides)
            }
        }
    }
}
