// Runs Vision recognition serially on an actor, returning editable text blocks in reading order.
import Foundation
import Vision
import CoreGraphics

struct OCRBlock: Identifiable, Sendable {
    var id = UUID()
    var text: String
    var boundingBox: CGRect
    var confidence: Float
    var selected = true
}

actor OCREngine {
    /// Recognizes a CGImage without moving Vision request state or pixel work onto MainActor.
    func recognize(_ image: CGImage, languages: [String] = ["zh-Hans", "en-US", "ja-JP"], accurate: Bool = true) throws -> [OCRBlock] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRBlock(text: candidate.string, boundingBox: observation.boundingBox, confidence: candidate.confidence)
        }.sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.015 { return $0.boundingBox.midY > $1.boundingBox.midY }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
    }
}

enum OCRTextProcessor {
    /// Applies explicit, reversible UI text transforms without altering source OCR blocks.
    static func process(_ text: String, mergeParagraphs: Bool, stripLineBreaks: Bool, englishPunctuation: Bool) -> String {
        var result = text
        if mergeParagraphs { result = result.replacingOccurrences(of: "\n\n", with: "\n").replacingOccurrences(of: "\n", with: " ") }
        if stripLineBreaks { result = result.replacingOccurrences(of: "\n", with: "") }
        if englishPunctuation {
            let mapping = ["，": ",", "。": ".", "！": "!", "？": "?", "：": ":", "；": ";", "（": "(", "）": ")", "【": "[", "】": "]", "“": "\"", "”": "\"", "‘": "'", "’": "'"]
            for (source, target) in mapping { result = result.replacingOccurrences(of: source, with: target) }
        }
        return result
    }
}
