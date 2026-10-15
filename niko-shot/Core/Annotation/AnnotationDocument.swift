// Defines serializable annotation items and snapshot-based undo/redo as the sole editing model.
import CoreGraphics
import Foundation

enum AnnotationTool: String, Codable, CaseIterable, Sendable {
    case rectangle, ellipse, arrow, line, pen, text, mosaic, blur, highlight, step, note, magnifier

    var title: String {
        switch self {
        case .rectangle: "矩形"; case .ellipse: "椭圆"; case .arrow: "箭头"; case .line: "直线"
        case .pen: "画笔"; case .text: "文字"; case .mosaic: "马赛克"; case .blur: "模糊"
        case .highlight: "高亮"; case .step: "序号"; case .note: "便签"; case .magnifier: "放大镜"
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: "rectangle"; case .ellipse: "circle"; case .arrow: "arrow.up.right"
        case .line: "line.diagonal"; case .pen: "scribble"; case .text: "textformat"
        case .mosaic: "checkerboard.rectangle"; case .blur: "drop.halffull"; case .highlight: "highlighter"
        case .step: "1.circle"; case .note: "note.text"; case .magnifier: "plus.magnifyingglass"
        }
    }

    /// Tools shown on the toolbar; blur and note are variants chosen in the property bar.
    static let toolbarTools: [AnnotationTool] = [.rectangle, .ellipse, .line, .arrow, .pen, .highlight, .mosaic, .text, .step, .magnifier]

    /// Spec key map: 1 rect, 2 ellipse, 3 line, 4 arrow, 5 pen, 6 mosaic, 7 text, 8 step, 9 highlight.
    static func forNumberKey(_ number: Int) -> AnnotationTool? {
        let map: [AnnotationTool] = [.rectangle, .ellipse, .line, .arrow, .pen, .mosaic, .text, .step, .highlight]
        return (1...9).contains(number) ? map[number - 1] : nil
    }

    var shortcutHint: String? {
        switch self {
        case .rectangle: "1"; case .ellipse: "2"; case .line: "3"; case .arrow: "4"; case .pen: "5"
        case .mosaic, .blur: "6"; case .text, .note: "7"; case .step: "8"; case .highlight: "9"; case .magnifier: nil
        }
    }

    /// The toolbar button that represents this tool (variants share one button).
    var toolbarTool: AnnotationTool {
        switch self {
        case .blur: .mosaic
        case .note: .text
        default: self
        }
    }

    var supportsFill: Bool { self == .rectangle || self == .ellipse }
    var isTextual: Bool { self == .text || self == .note }
    var isEffect: Bool { self == .mosaic || self == .blur }
    var isFreehand: Bool { self == .pen }
    var isLinear: Bool { self == .line || self == .arrow }
}

struct AnnotationColor: Codable, Equatable, Sendable {
    var red: Double, green: Double, blue: Double, alpha: Double
    static let red = AnnotationColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
    var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: alpha) }

    /// Perceived brightness, used to pick readable text on step badges.
    var luminance: Double { 0.299 * red + 0.587 * green + 0.114 * blue }

    static let palette: [(name: String, color: AnnotationColor)] = [
        ("红色", AnnotationColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)),
        ("橙色", AnnotationColor(red: 1, green: 0.58, blue: 0, alpha: 1)),
        ("黄色", AnnotationColor(red: 1, green: 0.8, blue: 0, alpha: 1)),
        ("绿色", AnnotationColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)),
        ("蓝色", AnnotationColor(red: 0, green: 0.48, blue: 1, alpha: 1)),
        ("紫色", AnnotationColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)),
        ("白色", AnnotationColor(red: 1, green: 1, blue: 1, alpha: 1)),
        ("黑色", AnnotationColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1))
    ]
}

struct FontSnapshot: Codable, Equatable, Sendable {
    var postScriptName = "PingFangSC-Semibold"
    var pointSize: CGFloat = 20
}

/// Current drawing style; also applied to a selected item when the property bar changes.
struct AnnotationStyle: Equatable, Sendable {
    var color: AnnotationColor = .red
    /// Stroke width in points; mosaic block strength and step badge size derive from it.
    var width: CGFloat = 4
    var filled = false
    var fontSize: CGFloat = 20
    /// Text drawn on a sticky-note background.
    var textBackground = false
    /// Mosaic drawn as a soft blur instead of square blocks.
    var blur = false

    /// Three size presets shown in the property bar.
    static let widthPresets: [CGFloat] = [2, 4, 8]
    static let fontPresets: [CGFloat] = [15, 20, 30]
}

protocol AnnotationCommand: Codable, Equatable, Sendable {
    var id: UUID { get }
    var color: AnnotationColor { get }
}

struct AnnotationItem: AnnotationCommand {
    var id = UUID()
    var tool: AnnotationTool
    var color: AnnotationColor = .red
    var width: CGFloat = 4
    var rect: CGRect = .zero
    var points: [CGPoint] = []
    var text = ""
    var font = FontSnapshot()
    var number = 1
    var filled = false

    init(id: UUID = UUID(), tool: AnnotationTool, color: AnnotationColor = .red, width: CGFloat = 4,
         rect: CGRect = .zero, points: [CGPoint] = [], text: String = "", font: FontSnapshot = FontSnapshot(),
         number: Int = 1, filled: Bool = false) {
        self.id = id; self.tool = tool; self.color = color; self.width = width; self.rect = rect
        self.points = points; self.text = text; self.font = font; self.number = number; self.filled = filled
    }

    private enum CodingKeys: String, CodingKey { case id, tool, color, width, rect, points, text, font, number, filled }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        tool = try values.decode(AnnotationTool.self, forKey: .tool)
        color = try values.decodeIfPresent(AnnotationColor.self, forKey: .color) ?? .red
        width = try values.decodeIfPresent(CGFloat.self, forKey: .width) ?? 4
        rect = try values.decodeIfPresent(CGRect.self, forKey: .rect) ?? .zero
        points = try values.decodeIfPresent([CGPoint].self, forKey: .points) ?? []
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        font = try values.decodeIfPresent(FontSnapshot.self, forKey: .font) ?? FontSnapshot()
        number = try values.decodeIfPresent(Int.self, forKey: .number) ?? 1
        filled = try values.decodeIfPresent(Bool.self, forKey: .filled) ?? false
    }

    /// Bounds that contain everything this item paints, used for hit testing and selection chrome.
    var bounds: CGRect {
        switch tool {
        case .line, .arrow, .pen:
            guard let first = points.first else { return rect }
            var box = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() { box = box.union(CGRect(origin: point, size: .zero)) }
            return box.insetBy(dx: -width / 2, dy: -width / 2)
        case .step:
            let radius = AnnotationItem.stepDiameter(for: width) / 2
            return CGRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2)
        default:
            return rect.standardized
        }
    }

    static func stepDiameter(for width: CGFloat) -> CGFloat { 18 + width * 2.5 }

    /// Moves every coordinate by the same offset.
    mutating func translate(by delta: CGPoint) {
        rect = rect.offsetBy(dx: delta.x, dy: delta.y)
        points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }
}

struct AnnotationDocument: Codable, Equatable, Sendable {
    var canvasSize: CGSize
    private(set) var commands: [AnnotationItem] = []
    private var undoStack: [[AnnotationItem]] = []
    private var redoStack: [[AnnotationItem]] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    private enum CodingKeys: CodingKey { case canvasSize, commands }

    init(canvasSize: CGSize) { self.canvasSize = canvasSize }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canvasSize = try container.decode(CGSize.self, forKey: .canvasSize)
        commands = try container.decode([AnnotationItem].self, forKey: .commands)
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canvasSize, forKey: .canvasSize)
        try container.encode(commands, forKey: .commands)
    }

    /// Commits a command and invalidates any redo branch.
    mutating func append(_ command: AnnotationItem) { checkpoint(); commands.append(command) }
    /// Replaces an existing item (move, resize, restyle, edited text) as one undoable step.
    mutating func replace(_ command: AnnotationItem) {
        guard let index = commands.firstIndex(where: { $0.id == command.id }), commands[index] != command else { return }
        checkpoint(); commands[index] = command
    }
    mutating func remove(id: UUID) {
        guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
        checkpoint(); commands.remove(at: index)
    }
    mutating func removeAll() {
        guard !commands.isEmpty else { return }
        checkpoint(); commands.removeAll()
    }
    mutating func undo() { guard let previous = undoStack.popLast() else { return }; redoStack.append(commands); commands = previous }
    mutating func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(commands); commands = next }
    func item(id: UUID) -> AnnotationItem? { commands.first { $0.id == id } }
    /// Next number for a step badge: one more than the highest existing number.
    var nextStepNumber: Int { (commands.filter { $0.tool == .step }.map(\.number).max() ?? 0) + 1 }

    /// Keeps annotations anchored to the captured world after adjusting the selection rectangle.
    mutating func rebase(by delta: CGPoint, canvasSize: CGSize) {
        self.canvasSize = canvasSize
        commands = commands.map { command in
            var updated = command
            updated.translate(by: delta)
            return updated
        }
        undoStack.removeAll(); redoStack.removeAll()
    }

    private mutating func checkpoint() {
        undoStack.append(commands)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
}
