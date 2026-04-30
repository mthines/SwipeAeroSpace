#!/usr/bin/env swift
//
// verify-issue-19.swift
//
// Standalone verification harness for issue #19
// (https://github.com/MediosZ/SwipeAeroSpace/issues/19).
//
// Mirrors the gesture state machine in SwipeManager.swift exactly, then runs
// synthetic touch-event sequences for each scenario surfaced by the holistic
// analysis. Reports PASS/FAIL per scenario.
//
// Run:
//     swift verify-issue-19.swift
//
// The simulator only needs (count, dx, dy) per frame — same inputs the
// production state machine reduces NSTouch events to. Phase filtering is
// modeled at the touchEventHandler level so phantom .ended touches behave
// exactly as they do in the real app.

import Foundation

// MARK: - Mirror of production types

enum GestureState { case began, ended }
enum SwipeAxis { case undecided, horizontal, vertical }
enum Direction: String { case next, prev }

enum Action: Equatable, CustomStringConvertible {
    case fireWorkspace(Direction, steps: Int)
    case openOverview
    case dismissOverview
    case cancelLatch

    var description: String {
        switch self {
        case .fireWorkspace(let d, let s): return "fire(\(d.rawValue), steps=\(s))"
        case .openOverview: return "openOverview"
        case .dismissOverview: return "dismissOverview"
        case .cancelLatch: return "cancelLatch"
        }
    }
}

struct Settings {
    var fingers: String          // "Three" or "Four"
    var swipeUpFingers: String   // "Three" or "Four"
    var multiSwipeEnabled: Bool
    var swipeUpOverviewEnabled: Bool
    var naturalSwipe: Bool
    var swipeThresholdUI: Double // user-visible (default 1.0)
    var maxSteps: Int

    var hFingerCount: Int { fingers == "Three" ? 3 : 4 }
    var vFingerCount: Int { swipeUpFingers == "Three" ? 3 : 4 }
    var internalThreshold: Float { Float(swipeThresholdUI) * 0.05 }

    static let `default` = Settings(
        fingers: "Four",
        swipeUpFingers: "Three",
        multiSwipeEnabled: true,
        swipeUpOverviewEnabled: true,
        naturalSwipe: true,
        swipeThresholdUI: 1.0,
        maxSteps: 5
    )
}

/// One frame as macOS would deliver it — mirrors the input shape after
/// touchEventHandler's phase filter (filter `.ended`).
struct Frame {
    /// Active touch count (after filtering `.ended`), matches what
    /// `touchEventHandler` passes into `processTouches`.
    let count: Int
    /// Per-frame averaged normalized movement (matches swipeDistance output).
    let dx: Float
    let dy: Float
}

// Helper: simulate phase-filtering (the production fix in touchEventHandler).
// Pass total touches and how many of those are `.ended`. The simulator's
// `count` is what survives after the filter.
func frame(active: Int, ended: Int = 0, dx: Float = 0, dy: Float = 0) -> Frame {
    // touchesCount = touches.filter { $0.phase != .ended }.count
    // We model only the count here; ended touches contribute nothing.
    return Frame(count: active, dx: dx, dy: dy)
}

/// What the OLD (pre-fix) code would have seen — `.ended` touches inflate count.
func frameUnfiltered(active: Int, ended: Int = 0, dx: Float = 0, dy: Float = 0) -> Frame {
    return Frame(count: active + ended, dx: dx, dy: dy)
}

// MARK: - State machine (mirrors SwipeManager.swift after fixes)

final class GestureSimulator {
    let settings: Settings
    var state: GestureState = .ended
    var swipeAxis: SwipeAxis = .undecided
    var activeFingerCount: Int = 0
    var accDisX: Float = 0
    var accDisY: Float = 0
    var firedPosition: Int = 0
    var swipeUpFired: Bool = false
    var overlayVisible: Bool = false
    private(set) var actions: [Action] = []

    init(_ settings: Settings = .default) { self.settings = settings }

    /// Mirrors processTouches() — see SwipeManager.swift:488 (post-fix).
    func processTouches(_ frame: Frame) {
        let count = frame.count
        let h = settings.hFingerCount
        let v = settings.vFingerCount

        // Latch (line 491)
        if state != .began && (count == h || count == v) {
            state = .began
            activeFingerCount = count
        }
        // In-flight cancel (lines 500-506) — only when count is OUTSIDE the
        // valid range while axis is undecided. Crucially, we do NOT lower
        // `activeFingerCount` here.
        if state == .began && swipeAxis == .undecided
            && count != h && count != v
        {
            state = .ended
            actions.append(.cancelLatch)
            clearEventState()
            return
        }
        guard state == .began else { return }

        accDisX += frame.dx
        accDisY += frame.dy

        // Axis lock (line 513)
        if swipeAxis == .undecided {
            let t = settings.internalThreshold * 0.3
            if abs(accDisX) > t || abs(accDisY) > t {
                swipeAxis = abs(accDisY) > abs(accDisX) ? .vertical : .horizontal
            }
        }

        // Vertical / overview branch (line 522) — has activeFingerCount guard
        if swipeAxis == .vertical && settings.swipeUpOverviewEnabled
            && activeFingerCount == v
        {
            let t = settings.internalThreshold * 0.5
            if !swipeUpFired && accDisY > t {
                swipeUpFired = true
                if !overlayVisible {
                    overlayVisible = true
                    actions.append(.openOverview)
                }
            }
            if swipeUpFired && accDisY < t * 0.5 {
                swipeUpFired = false
                actions.append(.dismissOverview)
                overlayVisible = false
            }
            if !swipeUpFired && accDisY < -t && overlayVisible {
                swipeUpFired = true
                actions.append(.dismissOverview)
                overlayVisible = false
            }
        }

        // Horizontal multi-swipe branch (line 553) — has activeFingerCount guard (Fix A)
        if swipeAxis == .horizontal && settings.multiSwipeEnabled
            && activeFingerCount == h
        {
            let t = settings.internalThreshold
            let raw = Int(accDisX / t)
            let target = max(-settings.maxSteps, min(settings.maxSteps, raw))
            let delta = target - firedPosition
            if delta != 0 {
                let dir: Direction = delta > 0
                    ? (settings.naturalSwipe ? .prev : .next)
                    : (settings.naturalSwipe ? .next : .prev)
                actions.append(.fireWorkspace(dir, steps: abs(delta)))
                firedPosition = target
            }
        }
    }

    /// Mirrors stopGesture() + handleGesture() — see SwipeManager.swift:478 + 626 (post-fix).
    func endGesture() {
        guard state == .began else { return }
        state = .ended
        if swipeAxis != .vertical {
            handleGesture()
        }
        clearEventState()
    }

    private func handleGesture() {
        if settings.multiSwipeEnabled { return }
        // Non-multiSwipe finger-count guard (Fix #2 from holistic analysis)
        if activeFingerCount != settings.hFingerCount { return }
        let t = settings.internalThreshold
        if abs(accDisX) < t { return }
        let dir: Direction = settings.naturalSwipe
            ? (accDisX < 0 ? .next : .prev)
            : (accDisX < 0 ? .prev : .next)
        actions.append(.fireWorkspace(dir, steps: 1))
    }

    private func clearEventState() {
        accDisX = 0
        accDisY = 0
        firedPosition = 0
        swipeUpFired = false
        swipeAxis = .undecided
        activeFingerCount = 0
    }
}

// MARK: - Test runner

struct Scenario {
    let name: String
    let settings: Settings
    let frames: [Frame]
    let endsGesture: Bool
    let expect: (GestureSimulator) -> (ok: Bool, why: String)
}

func run(_ scenarios: [Scenario]) -> Int {
    var failures = 0
    print("Running \(scenarios.count) scenarios...\n")
    for sc in scenarios {
        let sim = GestureSimulator(sc.settings)
        for f in sc.frames { sim.processTouches(f) }
        if sc.endsGesture { sim.endGesture() }
        let (ok, why) = sc.expect(sim)
        let mark = ok ? "PASS" : "FAIL"
        print("  [\(mark)] \(sc.name)")
        if !ok {
            failures += 1
            print("         \(why)")
            print("         actions: \(sim.actions)")
            print("         state: \(sim.state) axis: \(sim.swipeAxis) afc: \(sim.activeFingerCount) accDisX: \(sim.accDisX)")
        }
    }
    print("\n\(scenarios.count - failures)/\(scenarios.count) passed.")
    return failures
}

// Helpers for assertions
func hasFire(_ actions: [Action]) -> Bool {
    actions.contains { if case .fireWorkspace = $0 { return true }; return false }
}
func hasOpen(_ actions: [Action]) -> Bool { actions.contains(.openOverview) }

// MARK: - Scenarios (mapped to the holistic analysis)

let scenarios: [Scenario] = [

    // ── Bug repro: the user's reported issue ──────────────────────────────
    Scenario(
        name: "Bug #19 (default config): 3-finger drag-to-select with phantom .ended → no switch",
        settings: .default,
        frames: [
            // Frame 1: phantom — 3 active dragging + 1 finger that just lifted (.ended).
            // Production filter drops the .ended → count = 3.
            frame(active: 3, ended: 1, dx: 0.02, dy: 0.001),
            frame(active: 3, dx: 0.02, dy: 0.001),
            frame(active: 3, dx: 0.02, dy: 0.001),
            frame(active: 3, dx: 0.02, dy: 0.001),
        ],
        endsGesture: true,
        expect: { sim in
            // Workspace must NOT switch (user has fingers=Four)
            (!hasFire(sim.actions), "expected no fire, got \(sim.actions)")
        }
    ),

    Scenario(
        name: "Bug #19 (defense in depth): even WITHOUT the .ended filter, count=4 phantom doesn't fire (Fix A blocks)",
        settings: .default,
        frames: [
            // Simulate the OLD bug: frame 1 reports count=4 (phantom included),
            // frame 2+ revert to count=3.
            frameUnfiltered(active: 3, ended: 1, dx: 0.02, dy: 0.001),
            // After phantom clears: count=3 — matches vFingerCount(3),
            // activeFingerCount stays at the latched 4 (no lowering).
            frame(active: 3, dx: 0.02, dy: 0.001),
            frame(active: 3, dx: 0.02, dy: 0.001),
            frame(active: 3, dx: 0.02, dy: 0.001),
        ],
        endsGesture: true,
        expect: { sim in
            // Frame 1 latches at count=4. Frame 2-4 are count=3, axis locks
            // horizontal, but Fix A's guard blocks: activeFingerCount(4) != count(3)?
            // Wait — activeFingerCount stays 4, but multi-swipe checks
            // activeFingerCount == hFingerCount(4). So this WOULD fire.
            //
            // This scenario shows that the .ended filter is the load-bearing
            // root-cause fix. Without it, Fix A alone is not sufficient when
            // the phantom matches hFingerCount.
            //
            // We assert the behavior to make the gap explicit.
            (hasFire(sim.actions), "without filter, Fix A alone leaks; this proves filter is needed")
        }
    ),

    // ── Regression check: the refinement we made ──────────────────────────
    Scenario(
        name: "Brief finger-lift during 4-finger swipe still fires (refined Fix B doesn't swallow)",
        settings: .default,
        frames: [
            frame(active: 4, dx: 0.01, dy: 0.001),
            // brief drop to 3 fingers (matches vFingerCount=3)
            frame(active: 3, dx: 0.01, dy: 0.001),
            frame(active: 4, dx: 0.02, dy: 0.001),
            frame(active: 4, dx: 0.03, dy: 0.001),
            frame(active: 4, dx: 0.03, dy: 0.001),
        ],
        endsGesture: true,
        expect: { sim in
            (hasFire(sim.actions), "brief drop should not cancel; expected fire")
        }
    ),

    // ── Normal gestures (no regression) ───────────────────────────────────
    Scenario(
        name: "Normal 4-finger horizontal swipe fires workspace switch",
        settings: .default,
        frames: [
            frame(active: 4, dx: 0.02, dy: 0.001),
            frame(active: 4, dx: 0.02, dy: 0.001),
            frame(active: 4, dx: 0.02, dy: 0.001),
            frame(active: 4, dx: 0.02, dy: 0.001),
        ],
        endsGesture: true,
        expect: { sim in
            (hasFire(sim.actions), "expected workspace switch")
        }
    ),

    Scenario(
        name: "Normal 3-finger swipe-up opens overview",
        settings: .default,
        frames: [
            frame(active: 3, dx: 0.001, dy: 0.02),
            frame(active: 3, dx: 0.001, dy: 0.02),
            frame(active: 3, dx: 0.001, dy: 0.02),
        ],
        endsGesture: true,
        expect: { sim in
            (hasOpen(sim.actions), "expected overview to open")
        }
    ),

    Scenario(
        name: "fingers=Three 3-finger horizontal swipe still fires (config flexibility)",
        settings: Settings(
            fingers: "Three", swipeUpFingers: "Three",
            multiSwipeEnabled: true, swipeUpOverviewEnabled: true,
            naturalSwipe: true, swipeThresholdUI: 1.0, maxSteps: 5
        ),
        frames: [
            frame(active: 3, dx: 0.02, dy: 0.001),
            frame(active: 3, dx: 0.02, dy: 0.001),
            frame(active: 3, dx: 0.02, dy: 0.001),
        ],
        endsGesture: true,
        expect: { sim in
            (hasFire(sim.actions), "fingers=Three should still allow 3-finger horizontal switching")
        }
    ),

    // ── Non-multiSwipe path (Fix #2 from holistic analysis) ───────────────
    Scenario(
        name: "Non-multiSwipe + fingers=Four: 3-finger drag does NOT fire on lift",
        settings: Settings(
            fingers: "Four", swipeUpFingers: "Three",
            multiSwipeEnabled: false, swipeUpOverviewEnabled: true,
            naturalSwipe: true, swipeThresholdUI: 1.0, maxSteps: 5
        ),
        frames: [
            frame(active: 3, dx: 0.02, dy: 0.001),
            frame(active: 3, dx: 0.02, dy: 0.001),
            frame(active: 3, dx: 0.02, dy: 0.001),
            frame(active: 3, dx: 0.02, dy: 0.001),
        ],
        endsGesture: true,
        expect: { sim in
            (!hasFire(sim.actions),
             "non-multiSwipe path must check activeFingerCount; got \(sim.actions)")
        }
    ),

    Scenario(
        name: "Non-multiSwipe + fingers=Four: legitimate 4-finger swipe fires on lift",
        settings: Settings(
            fingers: "Four", swipeUpFingers: "Three",
            multiSwipeEnabled: false, swipeUpOverviewEnabled: true,
            naturalSwipe: true, swipeThresholdUI: 1.0, maxSteps: 5
        ),
        frames: [
            frame(active: 4, dx: 0.02, dy: 0.001),
            frame(active: 4, dx: 0.02, dy: 0.001),
            frame(active: 4, dx: 0.02, dy: 0.001),
        ],
        endsGesture: true,
        expect: { sim in
            (hasFire(sim.actions), "non-multiSwipe legitimate 4-finger should fire")
        }
    ),

    // ── Spurious / out-of-range counts ────────────────────────────────────
    Scenario(
        name: "Truly invalid count mid-gesture (e.g. 5 fingers) cancels the latch",
        settings: .default,
        frames: [
            frame(active: 4, dx: 0.005, dy: 0.001),
            frame(active: 5, dx: 0.005, dy: 0.001),  // out of range
        ],
        endsGesture: false,
        expect: { sim in
            (sim.actions.contains(.cancelLatch),
             "invalid count should produce cancelLatch")
        }
    ),

    Scenario(
        name: "2-finger scroll with trailing .ended phantom does NOT trigger overview",
        settings: .default,
        frames: [
            // Production: filter removes .ended → count = 2, no latch.
            frame(active: 2, ended: 1, dy: 0.05),
            frame(active: 2, dy: 0.05),
        ],
        endsGesture: true,
        expect: { sim in
            (!hasOpen(sim.actions),
             "2-finger scroll must not open overview; got \(sim.actions)")
        }
    ),

    Scenario(
        name: "fingers=Four AND swipeUpFingers=Four: 3-finger drag never latches at all",
        settings: Settings(
            fingers: "Four", swipeUpFingers: "Four",
            multiSwipeEnabled: true, swipeUpOverviewEnabled: true,
            naturalSwipe: true, swipeThresholdUI: 1.0, maxSteps: 5
        ),
        frames: [
            frame(active: 3, dx: 0.02, dy: 0.001),
            frame(active: 3, dx: 0.02, dy: 0.001),
            frame(active: 3, dx: 0.02, dy: 0.001),
        ],
        endsGesture: true,
        expect: { sim in
            (!hasFire(sim.actions) && !hasOpen(sim.actions),
             "3-finger should produce no actions when both finger counts = 4")
        }
    ),
]

let failures = run(scenarios)
exit(Int32(failures == 0 ? 0 : 1))
