// 自动滚动只派发像素滚轮事件；事件观察与捕获由会话内的 ScrollEventMonitor 负责。
import AppKit
@preconcurrency import ApplicationServices // The SDK exports the immutable AX prompt key as a legacy C var; it is read only on MainActor.
import os

/// 自动与手动模式共用会话选择的拼接引擎。
public enum ScrollCaptureMode: String, CaseIterable, Sendable, Identifiable {
    case automatic, manual
    /// Stable identity for native mode pickers.
    public var id: String { rawValue }
    /// Localized mode title.
    public var title: String { self == .automatic ? "自动滚动" : "手动滚动" }
}

/// 前 9 步为 1px，随后为 5px；累积计数在同一自动滚动会话中不随抓帧完成重置。
struct ProgressiveScrollStep {
    private(set) var stepCount = 0
    mutating func next() -> CGFloat {
        stepCount = min(Int.max - 2, stepCount) + 2
        return stepCount <= 19 ? 1 : 5
    }
}

/// 专用的可停止线程只产生 16ms 节奏；派发前回到 MainActor 校验真实目标，避免误滚其它窗口。
final class AutoScrollLoop: @unchecked Sendable {
    private struct State {
        var active = true
        var exited = false
        var continuations: [CheckedContinuation<Void, Never>] = []
        var stepCount = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onStep: @MainActor @Sendable (CGFloat) -> Void
    private var thread: Thread?
    var isRunning: Bool { state.withLock { !$0.exited } }
    var stepCount: Int { state.withLock { $0.stepCount } }

    @MainActor
    init(initialStepCount: Int = 0, onStep: @escaping @MainActor @Sendable (CGFloat) -> Void) {
        self.onStep = onStep
        state.withLock { $0.stepCount = max(0, initialStepCount) }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "niko-shot.scroll-events"; thread.qualityOfService = .userInitiated
        self.thread = thread; thread.start()
    }

    private func run() {
        var step = ProgressiveScrollStep(stepCount: stepCount)
        while state.withLock({ $0.active }) {
            let speed = step.next()
            let count = step.stepCount
            state.withLock { $0.stepCount = count }
            Task { @MainActor [weak self] in
                guard let self, self.state.withLock({ $0.active }) else { return }
                self.onStep(speed)
            }
            Thread.sleep(forTimeInterval: 0.016)
        }
        let waiting = state.withLock { value in
            value.exited = true
            let pending = value.continuations; value.continuations.removeAll(); return pending
        }
        for continuation in waiting { continuation.resume() }
    }

    func requestStop() { state.withLock { $0.active = false } }
    func stop() async {
        requestStop()
        await withCheckedContinuation { continuation in
            let finished = state.withLock { value in
                if value.exited { return true }
                value.continuations.append(continuation); return false
            }
            if finished { continuation.resume() }
        }
    }
}

@MainActor
enum AutoScroller {
    static let eventMarker: Int64 = 0x4e494b4f53484f54
    /// Reads Accessibility consent without requesting input-monitoring permission.
    static var isAuthorized: Bool { AXIsProcessTrusted() }

    /// Requests only the consent required to dispatch an automatic scroll step.
    static func requestAuthorization() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Opens the system Accessibility pane for users who want to enable automatic mode.
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Dispatches one downward step at a CoreGraphics global top-left point.
    static func step(points: CGFloat, at location: CGPoint) throws {
        guard isAuthorized else { throw AppError.permission("辅助功能") }
        guard points.isFinite, points > 0, location.x.isFinite, location.y.isFinite,
              let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                  wheel1: -Int32(min(8_192, max(1, points.rounded()))), wheel2: 0, wheel3: 0) else {
            throw AppError.file("无法派发滚动事件，请切换手动模式。")
        }
        event.location = location
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        event.post(tap: .cghidEventTap)
    }
}
