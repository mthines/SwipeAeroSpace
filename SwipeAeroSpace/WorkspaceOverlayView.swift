import Cocoa
import SwiftUI

struct WorkspaceInfo: Identifiable {
    let id: String  // workspace name
    let windows: [WindowInfo]
    let isFocused: Bool
}

struct WindowInfo: Identifiable {
    let id: String
    let appName: String
    let windowTitle: String
}

struct WorkspaceOverlayView: View {
    let workspaces: [WorkspaceInfo]
    let onSelect: (String) -> Void
    let onDismiss: () -> Void
    @State private var appeared = false

    private var columnCount: Int {
        min(workspaces.count, 5)
    }

    private let maxColumns = 5

    private var rows: [[WorkspaceInfo]] {
        stride(from: 0, to: workspaces.count, by: maxColumns).map {
            Array(workspaces[$0..<min($0 + maxColumns, workspaces.count)])
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Workspaces")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(row) { ws in
                            WorkspaceCard(workspace: ws)
                                .onTapGesture { onSelect(ws.id) }
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 20)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .scaleEffect(appeared ? 1 : 0.98)
        .onExitCommand { onDismiss() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.06)) {
                appeared = true
            }
        }
    }
}

struct WorkspaceCard: View {
    let workspace: WorkspaceInfo
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(workspace.id)
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                if workspace.isFocused {
                    Circle()
                        .fill(.blue)
                        .frame(width: 7, height: 7)
                }
            }

            Rectangle()
                .fill(Color.white.opacity(isHovered ? 0.3 : 0.15))
                .frame(height: 1)

            if workspace.windows.isEmpty {
                Text("(empty)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(workspace.windows) { win in
                        HStack(spacing: 5) {
                            let icon = NSWorkspace.shared.icon(
                                forFile: appPath(for: win.appName))
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 15, height: 15)
                            Text(win.appName)
                                .font(.system(size: 12))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .frame(width: 150, alignment: .leading)
        .padding(10)
        .background(
            workspace.isFocused
                ? Color.accentColor.opacity(isHovered ? 0.35 : 0.15)
                : Color.white.opacity(isHovered ? 0.15 : 0.05)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(isHovered ? 0.5 : 0), lineWidth: 2)
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .shadow(color: .accentColor.opacity(isHovered ? 0.2 : 0), radius: 8)
        .animation(.easeOut(duration: 0.08), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .contentShape(Rectangle())
    }

    private func appPath(for appName: String) -> String {
        "/Applications/\(appName).app"
    }
}

class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

class OverlayPanelController {
    private var panel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    func show(workspaces: [WorkspaceInfo], onSelect: @escaping (String) -> Void) {
        dismiss()

        let view = WorkspaceOverlayView(
            workspaces: workspaces,
            onSelect: { [weak self] ws in
                onSelect(ws)
                self?.dismiss()
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        let hostingView = NSHostingView(rootView: view)

        // Force layout and get intrinsic size
        let intrinsicSize = hostingView.intrinsicContentSize
        let width = max(intrinsicSize.width, 400)
        let height = max(intrinsicSize.height, 200)
        hostingView.setFrameSize(NSSize(width: width, height: height))

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        let panelWidth = min(width, screenFrame.width * 0.9)
        let panelHeight = min(height, screenFrame.height * 0.8)

        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.midY - panelHeight / 2

        let panel = KeyablePanel(
            contentRect: NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = hostingView

        // Activate the app briefly so the panel can receive key events
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        // Local monitor catches Escape when the panel is key
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 {
                self?.dismiss()
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let screenPoint = NSEvent.mouseLocation
                if let panel = self?.panel,
                    !NSPointInRect(screenPoint, panel.frame)
                {
                    self?.dismiss()
                }
            }
            return event
        }

        // Global monitor catches clicks/Escape when another app is focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 {
                self?.dismiss()
                return
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        if let localMonitor = localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }
}
