// 菜单尺寸使用点击所在屏幕的可见区域；AppKit 箭头和边框也必须留在屏幕内。
import Foundation

struct MenuPopupLayout {
    static func safeFrame(screen: CGRect, visible: CGRect, safeTop: CGFloat) -> CGRect {
        var frame = screen.intersection(visible)
        let top = min(frame.maxY, screen.maxY - max(0, safeTop))
        frame.size.height = max(0, top - frame.minY)
        return frame.insetBy(dx: 8, dy: 8)
    }

    static func contentSize(in available: CGRect) -> CGSize {
        CGSize(width: max(1, min(344, available.width - 20)),
               height: max(1, min(544, available.height - 30)))
    }

    static func clampedFrame(_ frame: CGRect, within available: CGRect) -> CGRect {
        CGRect(x: min(max(frame.minX, available.minX), available.maxX - frame.width),
               y: min(max(frame.minY, available.minY), available.maxY - frame.height),
               width: frame.width, height: frame.height)
    }
}
