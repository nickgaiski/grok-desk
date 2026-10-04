import AppKit
import SwiftUI
import SwiftTerm
import GrokDeskCore

@MainActor
final class PanelTerminal: ObservableObject, LocalProcessTerminalViewDelegate {
    let view=LocalProcessTerminalView(frame:.zero)
    @Published var exited=false
    @Published var title="Terminal"
    private var started=false
    init() { view.processDelegate=self;view.font = .monospacedSystemFont(ofSize:12,weight:.regular) }
    func start(cwd:String, launch: TerminalLaunch? = nil) {
        guard !started else{return};started=true
        var env=ProcessInfo.processInfo.environment;env["TERM"]="xterm-256color";env["COLORTERM"]="truecolor"
        view.startProcess(executable:launch?.executable ?? "/bin/zsh",args:launch?.arguments ?? ["-l"],environment:env.map { $0.key+"="+$0.value },currentDirectory:cwd)
    }
    func stop() {view.terminate();exited=true}
    nonisolated func sizeChanged(source:LocalProcessTerminalView,newCols:Int,newRows:Int) {}
    nonisolated func setTerminalTitle(source:LocalProcessTerminalView,title:String) {Task { @MainActor in self.title=title }}
    nonisolated func hostCurrentDirectoryUpdate(source:TerminalView,directory:String?) {}
    nonisolated func processTerminated(source:TerminalView,exitCode:Int32?) {Task { @MainActor in self.exited=true }}
}
struct EmbeddedTerminal: NSViewRepresentable {
    @ObservedObject var terminal:PanelTerminal
    let cwd:String
    var launch: TerminalLaunch? = nil
    @AppStorage("terminalFontSize") private var fontSize=12.0
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context:Context)->LocalProcessTerminalView {terminal.start(cwd:cwd, launch: launch);return terminal.view}
    func updateNSView(_ view:LocalProcessTerminalView,context:Context) { view.font = .monospacedSystemFont(ofSize:fontSize,weight:.regular); view.nativeForegroundColor = .labelColor; view.nativeBackgroundColor = scheme == .dark ? NSColor(white:0.10,alpha:1):NSColor(white:0.98,alpha:1) }
}
