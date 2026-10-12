// Defines serializable annotation commands and snapshot-based undo/redo as the sole editing model.
import CoreGraphics
import Foundation

enum AnnotationTool: String, Codable, CaseIterable, Sendable {
    case rectangle, ellipse, arrow, line, pen, text, mosaic, blur, highlight, step, note, magnifier
    var title: String {
        switch self {
        case .rectangle: "矩形"; case .ellipse: "椭圆"; case .arrow: "箭头"; case .line: "直线"
        case .pen: "画笔"; case .text: "文字"; case .mosaic: "马赛克"; case .blur: "模糊"
        case .highlight: "高亮"; case .step: "序号"; case .note: "便签"; case .magnifier: "放大标注"
        }
    }
    var symbol: String {
        switch self {
        case .rectangle: "rectangle"; case .ellipse: "circle"; case .arrow: "arrow.up.right"
        case .line: "line.diagonal"; case .pen: "pencil.tip"; case .text: "textformat"
        case .mosaic: "square.grid.3x3.fill"; case .blur: "drop.halffull"; case .highlight: "highlighter"
        case .step: "1.circle"; case .note: "note.text"; case .magnifier: "plus.magnifyingglass"
        }
    }
}

struct AnnotationColor: Codable, Equatable, Sendable {
    var red: Double, green: Double, blue: Double, alpha: Double
    static let red = AnnotationColor(red: 1, green: 0.23, blue: 0.2, alpha: 1)
    var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: alpha) }
}

struct FontSnapshot: Codable, Equatable, Sendable {
    var postScriptName = "Helvetica"
    var pointSize: CGFloat = 20
}

protocol AnnotationCommand: Codable, Equatable, Sendable {
    var id: UUID { get }
    var color: AnnotationColor { get }
}

struct AnnotationItem: AnnotationCommand {
    var id = UUID()
    var tool: AnnotationTool
    var color: AnnotationColor = .red
    var width: CGFloat = 3
    var rect: CGRect = .zero
    var points: [CGPoint] = []
    var text = ""
    var font = FontSnapshot()
    var number = 1
}

struct AnnotationDocument: Codable, Equatable, Sendable {
    var canvasSize: CGSize
    private(set) var commands: [AnnotationItem] = []
    private var undoStack: [[AnnotationItem]] = []
    private var redoStack: [[AnnotationItem]] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    private enum CodingKeys: CodingKey { case canvasSize, commands }

    /// Initializes an editable document using point coordinates, independent of export scale.
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
    mutating func append(_ command: AnnotationItem) { undoStack.append(commands); commands.append(command); redoStack.removeAll() }
    mutating func undo() { guard let previous = undoStack.popLast() else { return }; redoStack.append(commands); commands = previous }
    mutating func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(commands); commands = next }
    /// Keeps annotations anchored to the captured world after adjusting the selection rectangle.
    mutating func rebase(by delta: CGPoint, canvasSize: CGSize) {
        self.canvasSize = canvasSize
        commands = commands.map { command in
            var updated = command
            updated.rect = command.rect.offsetBy(dx: delta.x, dy: delta.y)
            updated.points = command.points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
            return updated
        }
        undoStack.removeAll(); redoStack.removeAll()
    }
}
