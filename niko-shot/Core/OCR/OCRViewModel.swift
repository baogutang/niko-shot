// Holds editable OCR UI state while preserving the original per-block Vision output.
import AppKit
import Observation

@MainActor @Observable
final class OCRViewModel {
    var blocks: [OCRBlock] = []
    var isRecognizing = false
    var errorMessage: String?
    var mergeParagraphs = false
    var stripLineBreaks = false
    var englishPunctuation = false
    var selectedText: String { OCRTextProcessor.process(blocks.filter(\.selected).map(\.text).joined(separator: "\n"), mergeParagraphs: mergeParagraphs, stripLineBreaks: stripLineBreaks, englishPunctuation: englishPunctuation) }
    func copySelected() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selectedText, forType: .string) }
    func copy(blockID: UUID) { guard let block = blocks.first(where: { $0.id == blockID }) else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(block.text, forType: .string) }
}
