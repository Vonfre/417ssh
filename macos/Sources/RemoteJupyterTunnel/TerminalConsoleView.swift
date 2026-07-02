import AppKit
import SwiftUI

struct TerminalConsoleView: NSViewRepresentable {
    @ObservedObject var terminal: TerminalManager
    let profileID: UUID

    func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView()
    }

    func updateNSView(_ hostView: TerminalHostView, context: Context) {
        hostView.attach(terminal.view(for: profileID))
    }

    static func dismantleNSView(_ hostView: TerminalHostView, coordinator: ()) {
        hostView.attach(nil)
    }
}

final class TerminalHostView: NSView {
    private weak var hostedTerminalView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
    }

    func attach(_ terminalView: NSView?) {
        if hostedTerminalView === terminalView {
            return
        }

        hostedTerminalView?.removeFromSuperview()
        hostedTerminalView = terminalView

        guard let terminalView else { return }
        terminalView.removeFromSuperview()
        terminalView.frame = bounds
        terminalView.autoresizingMask = [.width, .height]
        addSubview(terminalView)

        DispatchQueue.main.async { [weak terminalView] in
            terminalView?.window?.makeFirstResponder(terminalView)
        }
    }
}
