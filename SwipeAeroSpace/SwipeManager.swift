import Cocoa
import Foundation
import Socket
import SwiftUI
import os

enum Direction {
    case next
    case prev

    var value: String {
        switch self {
        case .next:
            "next"
        case .prev:
            "prev"
        }
    }
}

enum GestureState {
    case began
    case changed
    case ended
    case cancelled
}

enum SwipeAxis {
    case undecided
    case horizontal
    case vertical
}

enum SwipeError: Error {
    case SocketError(String)
    case CommandFail(String)
    case Unknown(String)
}

public struct ClientRequest: Codable, Sendable {
    public let command: String
    public let args: [String]
    public let stdin: String
    public let windowId: UInt32?
    public let workspace: String?

    public init(
        args: [String],
        stdin: String,
        windowId: UInt32?,
        workspace: String?
    ) {
        self.command = ""
        self.args = args
        self.stdin = stdin
        self.windowId = windowId
        self.workspace = workspace
    }
}

public struct ServerAnswer: Codable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let serverVersionAndHash: String

    public init(
        exitCode: Int32,
        stdout: String = "",
        stderr: String = "",
        serverVersionAndHash: String
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.serverVersionAndHash = serverVersionAndHash
    }
}

class SocketInfo: ObservableObject {
    @Published var socketConnected: Bool = false
}

extension Result {
    public var isSuccess: Bool {
        switch self {
        case .success: true
        case .failure: false
        }
    }
}

class SwipeManager {
    // user settings
    @AppStorage("threshold") private var swipeThreshold: Double = 0.15
    @AppStorage("wrap") private var wrapWorkspace: Bool = false
    @AppStorage("natrual") private var naturalSwipe: Bool = true
    @AppStorage("skip-empty") private var skipEmpty: Bool = false
    @AppStorage("fingers") private var fingers: String = "Three"
    @AppStorage("multiSwipe") private var multiSwipeEnabled: Bool = true
    @AppStorage("maxSteps") private var maxSteps: Int = 5
    @AppStorage("swipeUpOverview") private var swipeUpOverviewEnabled: Bool = true
    @AppStorage("swipeUpFingers") private var swipeUpFingers: String = "Three"

    var socketInfo = SocketInfo()

    private var eventTap: CFMachPort? = nil
    private var accDisX: Float = 0
    private var accDisY: Float = 0
    private var swipeUpFired: Bool = false
    private var firedPosition: Int = 0
    private var prevTouchPositions: [String: NSPoint] = [:]
    private var state: GestureState = .ended
    private var swipeAxis: SwipeAxis = .undecided
    private var activeFingerCount: Int = 0
    private var socket: Socket? = nil
    private let workQueue = DispatchQueue(label: "swipe.workspace", qos: .userInteractive)
    private let overlayController = OverlayPanelController()

    private var logger: Logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "Info"
    )

    private func runCommand(args: [String], stdin: String, retry: Bool = false)
        -> Result<String, SwipeError>
    {
        guard let socket = socket else {
            return .failure(.SocketError("No socket created"))
        }
        do {
            let request = try JSONEncoder().encode(
                ClientRequest(args: args, stdin: stdin, windowId: nil, workspace: nil)
            )
            try socket.write(from: request)
            let _ = try Socket.wait(
                for: [socket],
                timeout: 0,
                waitForever: true
            )
            var answer = Data()
            try socket.read(into: &answer)
            let result = try JSONDecoder().decode(
                ServerAnswer.self,
                from: answer
            )
            if result.exitCode != 0 {
                return .failure(.CommandFail(result.stderr))
            }
            return .success(result.stdout)

        } catch let error {
            guard let socketError = error as? Socket.Error else {
                return .failure(.Unknown(error.localizedDescription))
            }
            // if we encouter the socket error
            // try reconnect the socket and rerun the command only once.
            if retry {
                return .failure(.SocketError(socketError.localizedDescription))
            }
            logger.info("Trying reconnect socket...")
            connectSocket(reconnect: true)
            return runCommand(args: args, stdin: stdin, retry: true)
        }
    }

    private func getNonEmptyWorkspaces() -> Result<String, SwipeError> {
        let args = [
            "list-workspaces", "--monitor", "focused", "--empty", "no",
        ]
        return runCommand(args: args, stdin: "")
    }

    func showWorkspaceOverview() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let workspaces = self.queryWorkspaces()
            let originalWs = workspaces.first(where: { $0.isFocused })?.id
            DispatchQueue.main.async {
                self.overlayController.show(
                    workspaces: workspaces,
                    onSelect: { [weak self] wsName in
                        self?.workQueue.async {
                            _ = self?.runCommand(args: ["workspace", wsName], stdin: "")
                        }
                    },
                    onPreview: { [weak self] wsName in
                        self?.workQueue.async {
                            _ = self?.runCommand(args: ["workspace", wsName], stdin: "")
                        }
                    },
                    onRevert: { [weak self] in
                        guard let originalWs = originalWs else { return }
                        self?.workQueue.async {
                            _ = self?.runCommand(args: ["workspace", originalWs], stdin: "")
                        }
                    }
                )
            }
        }
    }

    private func queryWorkspaces() -> [WorkspaceInfo] {
        // Get focused workspace
        let focusedResult = runCommand(
            args: ["list-workspaces", "--focused"], stdin: ""
        )
        let focusedWs = (try? focusedResult.get())?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""

        // Get monitor names
        let monitorResult = runCommand(
            args: [
                "list-monitors", "--format", "%{monitor-id}|%{monitor-name}",
            ],
            stdin: ""
        )
        var monitorNames: [String: String] = [:]
        if let monitorOutput = try? monitorResult.get() {
            for line in monitorOutput.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1)
                if parts.count == 2 {
                    monitorNames[String(parts[0])] = String(parts[1])
                }
            }
        }

        // Get all non-empty workspaces on all monitors (with monitor IDs)
        let allResult = runCommand(
            args: [
                "list-workspaces", "--monitor", "all", "--empty", "no",
                "--format", "%{workspace}|%{monitor-id}",
            ],
            stdin: ""
        )
        guard let allOutput = try? allResult.get() else { return [] }
        let wsEntries: [(name: String, monitorId: String)] =
            allOutput.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "|", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (name: String(parts[0]), monitorId: String(parts[1]))
            }

        return wsEntries.compactMap { entry in
            let winResult = runCommand(
                args: [
                    "list-windows", "--workspace", entry.name,
                    "--format", "%{app-name}|%{window-title}",
                ],
                stdin: ""
            )
            let windows: [WindowInfo]
            if let winOutput = try? winResult.get(),
                !winOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                windows = winOutput.split(separator: "\n").enumerated().map {
                    idx, line in
                    let parts = line.split(separator: "|", maxSplits: 1)
                    return WindowInfo(
                        id: "\(entry.name)-\(idx)",
                        appName: parts.first.map(String.init) ?? "Unknown",
                        windowTitle: parts.count > 1
                            ? String(parts[1]) : ""
                    )
                }
            } else {
                windows = []
            }
            return WorkspaceInfo(
                id: entry.name,
                windows: windows,
                isFocused: entry.name == focusedWs,
                monitorId: entry.monitorId,
                monitorName: monitorNames[entry.monitorId] ?? "Monitor \(entry.monitorId)"
            )
        }
    }

    @discardableResult
    private func switchWorkspace(direction: Direction) -> Result<
        String, SwipeError
    > {

        var res = runCommand(
            args: ["list-workspaces", "--monitor", "mouse", "--visible"],
            stdin: ""
        )
        guard let mouse_on = try? res.get() else {
            return res
        }
        res = runCommand(args: ["workspace", mouse_on], stdin: "")
        guard (try? res.get()) != nil else {
            return res
        }

        var args = ["workspace", direction.value]
        if wrapWorkspace {
            args.append("--wrap-around")
        }
        var stdin = ""
        if skipEmpty {
            res = getNonEmptyWorkspaces()
            guard let ws = try? res.get() else {
                return res
            }
            stdin = ws
            if stdin != "" {
                // explicitly insert '--stdin'
                args.append("--stdin")
            }
        }
        return runCommand(args: args, stdin: stdin)
    }

    func nextWorkspace() {
        switch switchWorkspace(direction: .next) {
        case .success: return
        case .failure(let err): logger.error("\(err.localizedDescription)")
        }
    }

    func prevWorkspace() {
        switch switchWorkspace(direction: .prev) {
        case .success: return
        case .failure(let err): logger.error("\(err.localizedDescription)")
        }

    }

    func connectSocket(reconnect: Bool = false) {
        if socket != nil && !reconnect {
            logger.warning("socket is connected")
            return
        }

        let socket_path = "/tmp/bobko.aerospace-\(NSUserName()).sock"
        do {
            socket = try Socket.create(
                family: .unix,
                type: .stream,
                proto: .unix
            )
            try socket?.connect(to: socket_path)
            socketInfo.socketConnected = true
            logger.info("connect to socket \(socket_path)")
        } catch let error {
            logger.error("Unexpected error: \(error.localizedDescription)")
        }
    }

    func start() {
        if eventTap != nil {
            logger.warning("SwipeManager is already started")
            return
        }
        logger.info("SwipeManager start")
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: NSEvent.EventTypeMask.gesture.rawValue,
            callback: { proxy, type, cgEvent, me in
                let wrapper = Unmanaged<SwipeManager>.fromOpaque(me!)
                    .takeUnretainedValue()
                return wrapper.eventHandler(
                    proxy: proxy,
                    eventType: type,
                    cgEvent: cgEvent
                )
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        if eventTap == nil {
            logger.error("SwipeManager couldn't create event tap")
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            runLoopSource,
            CFRunLoopMode.commonModes
        )
        CGEvent.tapEnable(tap: eventTap!, enable: true)

        connectSocket()
    }

    func stop() {
        logger.info("stop the app")
        socket?.close()
    }

    private func eventHandler(
        proxy: CGEventTapProxy,
        eventType: CGEventType,
        cgEvent: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType.rawValue == NSEvent.EventType.gesture.rawValue,
            let nsEvent = NSEvent(cgEvent: cgEvent)
        {
            touchEventHandler(nsEvent)
        } else if eventType == .tapDisabledByUserInput
            || eventType == .tapDisabledByTimeout
        {
            logger.info("SwipeManager tap disabled \(eventType.rawValue)")
            CGEvent.tapEnable(tap: eventTap!, enable: true)
        }
        return Unmanaged.passUnretained(cgEvent)
    }

    private func touchEventHandler(_ nsEvent: NSEvent) {
        let touches = nsEvent.allTouches()

        // Sometimes there are empty touch events that we have to skip. There are no empty touch events if Mission Control or App Expose use 3-finger swipes though.
        if touches.isEmpty {
            return
        }
        let touchesCount =
            touches.allSatisfy({ $0.phase == .ended }) ? 0 : touches.count
        if touchesCount == 0 {
            stopGesture()
        } else {
            processTouches(touches: touches, count: touchesCount)
        }
    }

    private func stopGesture() {
        if state == .began {
            state = .ended
            if swipeAxis != .vertical {
                handleGesture()
            }
            clearEventState()
        }
    }

    private func processTouches(touches: Set<NSTouch>, count: Int) {
        let hFingerCount = fingers == "Three" ? 3 : 4
        let vFingerCount = swipeUpFingers == "Three" ? 3 : 4
        if state != .began && (count == hFingerCount || count == vFingerCount) {
            state = .began
            activeFingerCount = count
        }
        if state == .began {
            let (disX, disY) = swipeDistance(touches: touches)
            accDisX += disX
            accDisY += disY

            // Lock axis once we have enough movement
            if swipeAxis == .undecided {
                let threshold = Float(swipeThreshold) * 0.3
                if abs(accDisX) > threshold || abs(accDisY) > threshold {
                    swipeAxis =
                        abs(accDisY) > abs(accDisX) ? .vertical : .horizontal
                }
            }

            // Vertical swipes: only fire if finger count matches overview setting
            if swipeAxis == .vertical && swipeUpOverviewEnabled
                && activeFingerCount == vFingerCount
            {
                let threshold = Float(swipeThreshold) * 0.5
                if !swipeUpFired && accDisY > threshold {
                    swipeUpFired = true
                    if !overlayController.isVisible {
                        showWorkspaceOverview()
                    }
                }
                // Mid-gesture: swipe back down dismisses when accDisY reverses
                if swipeUpFired && accDisY < threshold * 0.5 {
                    swipeUpFired = false
                    DispatchQueue.main.async { [weak self] in
                        self?.overlayController.dismiss()
                    }
                }
                // New gesture: swipe down dismisses if overlay is already open
                if !swipeUpFired && accDisY < -threshold
                    && overlayController.isVisible
                {
                    swipeUpFired = true
                    DispatchQueue.main.async { [weak self] in
                        self?.overlayController.dismiss()
                    }
                }
            }

            // Only fire horizontal workspace switches for horizontal swipes
            if swipeAxis == .horizontal && multiSwipeEnabled {
                let threshold = Float(swipeThreshold)
                let rawPosition = Int(accDisX / threshold)
                let targetPosition = max(-maxSteps, min(maxSteps, rawPosition))
                let delta = targetPosition - firedPosition

                if delta != 0 {
                    let direction: Direction
                    if delta > 0 {
                        direction = naturalSwipe ? .prev : .next
                    } else {
                        direction = naturalSwipe ? .next : .prev
                    }
                    let stepsToFire = abs(delta)
                    firedPosition = targetPosition
                    workQueue.async { [weak self] in
                        guard let self = self else { return }
                        for _ in 0..<stepsToFire {
                            switch self.switchWorkspace(direction: direction) {
                            case .success: continue
                            case .failure(let err):
                                self.logger.error("\(err.localizedDescription)")
                                return
                            }
                        }
                    }
                }
            }
        }
    }

    private func clearEventState() {
        accDisX = 0
        accDisY = 0
        firedPosition = 0
        swipeUpFired = false
        swipeAxis = .undecided
        activeFingerCount = 0
        prevTouchPositions.removeAll()
    }

    private func handleGesture() {
        // If multi-swipe is enabled, switches already fired live during the gesture
        if multiSwipeEnabled {
            return
        }
        let threshold = Float(swipeThreshold)
        if abs(accDisX) < threshold {
            return
        }
        let direction: Direction =
            if naturalSwipe {
                accDisX < 0 ? .next : .prev
            } else {
                accDisX < 0 ? .prev : .next
            }
        workQueue.async { [weak self] in
            guard let self = self else { return }
            switch self.switchWorkspace(direction: direction) {
            case .success: return
            case .failure(let err):
                self.logger.error("\(err.localizedDescription)")
            }
        }
    }

    private func swipeDistance(touches: Set<NSTouch>) -> (Float, Float) {
        var allRight = true
        var allLeft = true
        var allUp = true
        var allDown = true
        var sumDisX = Float(0)
        var sumDisY = Float(0)
        for touch in touches {
            let (disX, disY) = touchDistance(touch)
            allRight = allRight && disX >= 0
            allLeft = allLeft && disX <= 0
            allUp = allUp && disY >= 0
            allDown = allDown && disY <= 0
            sumDisX += disX
            sumDisY += disY

            if touch.phase == .ended {
                prevTouchPositions.removeValue(forKey: "\(touch.identity)")
            } else {
                prevTouchPositions["\(touch.identity)"] =
                    touch.normalizedPosition
            }
        }

        var resultX = sumDisX
        var resultY = sumDisY

        // All fingers should move in the same direction for each axis.
        if !allRight && !allLeft {
            resultX = 0
        }
        if !allUp && !allDown {
            resultY = 0
        }

        return (resultX, resultY)
    }

    private func touchDistance(_ touch: NSTouch) -> (Float, Float) {
        guard let prevPosition = prevTouchPositions["\(touch.identity)"] else {
            return (0, 0)
        }
        let position = touch.normalizedPosition
        return (
            Float(position.x - prevPosition.x),
            Float(position.y - prevPosition.y)
        )
    }
}
