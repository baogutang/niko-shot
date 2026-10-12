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
        let configuration = try Self.configuration(languages: languages, accurate: accurate)
        var blocks = try Self.perform(image, configuration: configuration)
        // Vision's Chinese model can drop trailing katakana in an otherwise mixed line.
        // Recheck ambiguous CJK with the enabled Japanese model, retaining the primary
        // English/Chinese text and using only a native candidate's extended kana run.
        if configuration.level == .accurate,
           let japanese = configuration.languages.first(where: { $0.hasPrefix("ja-") }),
           configuration.languages.first != japanese, blocks.contains(where: { Self.containsCJK($0.text) }) {
            try Task.checkCancellation()
            let alternate = RecognitionConfiguration(level: .accurate,
                languages: [japanese] + configuration.languages.filter { $0 != japanese })
            let candidates = try Self.perform(image, configuration: alternate)
            for index in blocks.indices where Self.containsCJK(blocks[index].text) {
                let primary = blocks[index]
                let matched = candidates.filter { $0.confidence >= primary.confidence && Self.overlap(primary.boundingBox, $0.boundingBox) >= 0.5 }
                    .max { Self.overlap(primary.boundingBox, $0.boundingBox) < Self.overlap(primary.boundingBox, $1.boundingBox) }
                if let matched { blocks[index].text = Self.extendingKana(in: primary.text, using: matched.text) }
            }
        }
        try Task.checkCancellation()
        return blocks.sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.015 { return $0.boundingBox.midY > $1.boundingBox.midY }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
    }

    private struct RecognitionConfiguration {
        let level: VNRequestTextRecognitionLevel
        let languages: [String]
    }

    private nonisolated static func configuration(languages: [String], accurate: Bool) throws -> RecognitionConfiguration {
        try autoreleasepool {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = accurate ? .accurate : .fast
            var supported = Set(try request.supportedRecognitionLanguages())
            if !accurate, languages.contains(where: { !supported.contains($0) }) {
                let fastLanguages = supported
                request.recognitionLevel = .accurate
                let accurateLanguages = Set(try request.supportedRecognitionLanguages())
                if languages.contains(where: { !fastLanguages.contains($0) && accurateLanguages.contains($0) }) {
                    supported = accurateLanguages
                } else { request.recognitionLevel = .fast }
            }
            var seen = Set<String>()
            let selected = languages.filter { supported.contains($0) && seen.insert($0).inserted }
            guard languages.isEmpty || !selected.isEmpty else {
                throw NSError(domain: "niko-shot.ocr", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "当前 macOS 不支持所选识别语言。"])
            }
            return RecognitionConfiguration(level: request.recognitionLevel, languages: selected)
        }
    }

    private nonisolated static func perform(_ image: CGImage, configuration: RecognitionConfiguration) throws -> [OCRBlock] {
        try autoreleasepool {
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = configuration.level
            request.recognitionLanguages = configuration.languages
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRBlock(text: candidate.string, boundingBox: observation.boundingBox, confidence: candidate.confidence)
            }
        }
    }

    private nonisolated static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        let union = lhs.width * lhs.height + rhs.width * rhs.height - area
        return union > 0 ? area / union : 0
    }

    private nonisolated static func containsCJK(_ text: String) -> Bool {
        text.contains { isKana($0) || isHan($0) }
    }

    private nonisolated static func isKana(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            (0x3041...0x3096).contains($0.value) || (0x309D...0x309F).contains($0.value) ||
            (0x30A1...0x30FA).contains($0.value) || (0x30FC...0x30FE).contains($0.value) ||
            (0xFF66...0xFF9D).contains($0.value)
        }
    }

    private nonisolated static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) ||
            (0xF900...0xFAFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
        }
    }

    private nonisolated static func japaneseRuns(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = [], start: String.Index?, hasKana = false
        for index in text.indices {
            if isKana(text[index]) || isHan(text[index]) {
                if start == nil { start = index }
                hasKana = hasKana || isKana(text[index])
            } else if let beginning = start {
                if hasKana { ranges.append(beginning..<index) }
                start = nil; hasKana = false
            }
        }
        if let start, hasKana { ranges.append(start..<text.endIndex) }
        return ranges
    }

    private nonisolated static func extendingKana(in primary: String, using alternate: String) -> String {
        var edits: [(Range<String.Index>, Substring)] = []
        for run in japaneseRuns(in: alternate) {
            let candidate = alternate[run]
            let anchors = candidate.filter(isHan)
            var matches: [Range<String.Index>] = []
            for start in primary.indices {
                var cursor = start, anchor = anchors.startIndex
                if anchors.isEmpty {
                    guard isKana(primary[start]) else { continue }
                    while cursor < primary.endIndex, isKana(primary[cursor]) { cursor = primary.index(after: cursor) }
                } else {
                    guard primary[start] == anchors[anchor] else { continue }
                    while cursor < primary.endIndex, anchor < anchors.endIndex {
                        let character = primary[cursor]
                        if isHan(character) {
                            guard character == anchors[anchor] else { break }
                            anchor = anchors.index(after: anchor)
                        } else if !isKana(character), !character.isWhitespace { break }
                        cursor = primary.index(after: cursor)
                    }
                    guard anchor == anchors.endIndex else { continue }
                    while cursor < primary.endIndex, isKana(primary[cursor]) { cursor = primary.index(after: cursor) }
                }
                let original = primary[start..<cursor].filter { !$0.isWhitespace }
                guard candidate.count > original.count, !original.isEmpty,
                      isSubsequence(original, of: candidate) else { continue }
                matches.append(start..<cursor)
            }
            // Ambiguous repeated phrases are left unchanged instead of joining unrelated text.
            if matches.count == 1, let match = matches.first,
               !edits.contains(where: { $0.0.overlaps(match) }) { edits.append((match, candidate)) }
        }
        edits.sort { $0.0.lowerBound < $1.0.lowerBound }
        var result = "", cursor = primary.startIndex
        for (original, candidate) in edits {
            result += primary[cursor..<original.lowerBound]
            result += candidate
            cursor = original.upperBound
        }
        result += primary[cursor...]
        return result
    }

    private nonisolated static func isSubsequence(_ original: String, of candidate: Substring) -> Bool {
        var index = original.startIndex
        for character in candidate where index < original.endIndex {
            if character == original[index] { index = original.index(after: index) }
        }
        return index == original.endIndex
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
