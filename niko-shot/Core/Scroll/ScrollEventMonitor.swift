// 只在长截图激活期间监听滚轮；不监听键盘、文字输入或其它应用事件。
import AppKit

@MainActor
final class ScrollEventMonitor {
    static let finishDebounce: TimeInterval = 0.06
    private var local: Any?
    private var global: Any?
    private var timer: Timer?
    private var viewport: CGRect = .zero
    private var windowID: CGWindowID?
    private var onScroll: (() -> Void)?
    private var onFinished: (() -> Void)?
    var localMonitorCount: Int { local == nil ? 0 : 1 }
    var globalMonitorCount: Int { global == nil ? 0 : 1 }
    var timerCount: Int { timer?.isValid == true ? 1 : 0 }

    func start(viewport: CGRect, windowID: CGWindowID? = nil, onScroll: @escaping () -> Void, onFinished: @escaping () -> Void) {
        stop()
        self.viewport = viewport; self.onScroll = onScroll; self.onFinished = onFinished
        self.windowID = windowID
        local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
            return event
        }
        // AppKit 的 global monitor 在主线程回调，并且与 local monitor 的事件范围互斥。
        global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
        }
    }

    func update(viewport: CGRect) { self.viewport = viewport }

    func receive(_ event: NSEvent) {
        let point: CGPoint
        var target: Int64 = 0, synthetic = false
        if let native = event.cgEvent {
            synthetic = native.getIntegerValueField(.eventSourceUserData) == AutoScroller.eventMarker
            target = native.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
            if target == 0, event.windowNumber > 0 { target = Int64(event.windowNumber) }
            point = CGPoint(x: native.location.x,
                y: CoordinateSpace.flippedY(native.location.y, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0))
        } else { point = NSEvent.mouseLocation }
        guard event.scrollingDeltaY != 0 || event.momentumPhase == .ended || event.phase == .ended else { return }
        receiveScrollEvent(at: point, targetWindow: target, synthetic: synthetic)
    }

    /// WindowServer 的目标字段只读；无权限测试从同一个解码后的入口注入，不伪造系统窗口。
    func receiveScrollEvent(at point: CGPoint, targetWindow: Int64, synthetic: Bool = false) {
        // 预览/其它窗口在选区上方滚动不能让目标静止截图提前完成；未知字段仍按选区判断。
        if !synthetic, let windowID, targetWindow > 0, targetWindow != Int64(windowID) { return }
        guard viewport.contains(point) else { return }
        receiveScrollEvent()
    }

    /// 共享入口也用于无 TCC 的流程测试；只有滚动事件会重设结束计时。
    func receiveScrollEvent() {
        guard let onScroll else { return }
        timer?.invalidate()
        // 从事件到达计时，不能让 GPU 抓帧/拼接耗时偷偷延长这 60ms。
        timer = Timer.scheduledTimer(withTimeInterval: Self.finishDebounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer?.invalidate(); self.timer = nil
                self.onFinished?()
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        onScroll()
    }

    func stop() {
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil; global = nil
        timer?.invalidate(); timer = nil
        onScroll = nil; onFinished = nil; viewport = .zero; windowID = nil
    }
}
