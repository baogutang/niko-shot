// Runs Vision recognition serially on an actor, returning editable text blocks in reading order.
import Foundation
import Vision
import CoreGraphics

struct OCRScriptRun: Sendable {
    var range: Range<String.Index>
    var boundingBox: CGRect
    var hasKana: Bool
}

struct OCRBlock: Identifiable, Sendable {
    var id = UUID()
    var text: String
    var boundingBox: CGRect
    var confidence: Float
    var selected = true
    var scriptRuns: [OCRScriptRun] = []
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
           configuration.languages.first != japanese {
            try Task.checkCancellation()
            let alternate = RecognitionConfiguration(level: .accurate,
                languages: [japanese] + configuration.languages.filter { $0 != japanese })
            let candidates = try Self.perform(image, configuration: alternate)
            blocks = try Self.reconcile(image, primary: blocks, supplemental: candidates, languages: configuration.languages)
        }
        try Task.checkCancellation()
        return blocks.sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.015 { return $0.boundingBox.midY > $1.boundingBox.midY }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
    }

    /// Preserves independently detected lines and rechecks their Han-only spans
    /// without feeding the Japanese and Latin portions back into the Chinese decoder.
    nonisolated static func reconcile(_ image: CGImage, primary: [OCRBlock], supplemental: [OCRBlock], languages: [String]) throws -> [OCRBlock] {
        try Task.checkCancellation()
        var recovered = primary
        if languages.contains(where: { $0.hasPrefix("zh-") }) {
            let configuration = try Self.configuration(languages: languages, accurate: true)
            for candidate in supplemental where containsCJK(candidate.text) &&
                !recovered.contains(where: { overlap($0.boundingBox, candidate.boundingBox) > 0 }) {
                try Task.checkCancellation()
                recovered.append(try recoverHanRuns(image, candidate: candidate, configuration: configuration))
            }
        }
        return mergingRecognitions(primary: recovered, supplemental: supplemental)
    }

    /// Keeps primary Han and supplements disjoint observations, without duplicating
    /// a partially overlapping line or discarding a low-confidence independent line.
    nonisolated static func mergingRecognitions(primary: [OCRBlock], supplemental: [OCRBlock]) -> [OCRBlock] {
        var blocks = primary
        for index in primary.indices where containsCJK(primary[index].text) {
            let block = primary[index]
            let matched = supplemental.filter { $0.confidence >= block.confidence && overlap(block.boundingBox, $0.boundingBox) >= 0.5 }
                .max { overlap(block.boundingBox, $0.boundingBox) < overlap(block.boundingBox, $1.boundingBox) }
            if let matched {
                let extended = extendingKana(in: block.text, using: matched.text)
                if extended != block.text {
                    blocks[index].text = extended
                    blocks[index].scriptRuns = []
                }
            }
        }
        for candidate in supplemental where !blocks.contains(where: { overlap($0.boundingBox, candidate.boundingBox) > 0 }) {
            blocks.append(candidate)
        }
        return blocks
    }

    private nonisolated static func recoverHanRuns(_ image: CGImage, candidate: OCRBlock, configuration: RecognitionConfiguration) throws -> OCRBlock {
        var edits: [(Range<String.Index>, String)] = []
        var confidence = candidate.confidence
        for run in candidate.scriptRuns where !run.hasKana {
            try Task.checkCancellation()
            let recognized = try recognizeIsolatedHan(image, bounds: run.boundingBox,
                lineHeight: candidate.boundingBox.height, configuration: configuration)
            var best: (text: String, confidence: Float, score: CGFloat)?
            for block in recognized {
                for decoded in block.scriptRuns where !decoded.hasKana {
                    let score = overlap(run.boundingBox, decoded.boundingBox)
                    // Character boxes are approximate. Reject incidental overlap from
                    // neighboring glyphs admitted by the conservative crop margins.
                    if score >= 0.25, score > (best?.score ?? 0) {
                        best = (String(block.text[decoded.range]), block.confidence, score)
                    }
                }
            }
            if let best { edits.append((run.range, best.text)); confidence = min(confidence, best.confidence) }
        }
        guard !edits.isEmpty else { return candidate }
        edits.sort { $0.0.lowerBound < $1.0.lowerBound }
        var result = "", cursor = candidate.text.startIndex
        for (range, replacement) in edits {
            result += candidate.text[cursor..<range.lowerBound]
            result += replacement
            cursor = range.upperBound
        }
        result += candidate.text[cursor...]
        var corrected = candidate
        corrected.text = result
        corrected.confidence = confidence
        corrected.scriptRuns = [] // Ranges describe the original native candidate only.
        return corrected
    }

    private nonisolated static func recognizeIsolatedHan(_ image: CGImage, bounds: CGRect, lineHeight: CGFloat, configuration: RecognitionConfiguration) throws -> [OCRBlock] {
        try autoreleasepool {
            try Task.checkCancellation()
            let width = image.width, height = image.height
            // Vision documents character boxes as approximate UI geometry. Expand by
            // half a native line height to retain omitted edge glyphs, without scaling
            // pixels or inferring glyph width from the erroneous recognized string.
            let horizontalPadding = max(2, lineHeight * CGFloat(height) * 0.5)
            let verticalPadding = min(24, max(2, lineHeight * CGFloat(height) * 0.5))
            let region = bounds.insetBy(dx: -horizontalPadding / CGFloat(width), dy: -verticalPadding / CGFloat(height))
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !region.isNull, region.width > 0, region.height > 0 else { return [] }
            let cropRect = CGRect(x: region.minX * CGFloat(width), y: (1 - region.maxY) * CGFloat(height),
                width: region.width * CGFloat(width), height: region.height * CGFloat(height))
                .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard let crop = image.cropping(to: cropRect) else { return [] }
            try Task.checkCancellation()
            let recognized = try perform(crop, configuration: configuration)
            func mappedBounds(_ box: CGRect) -> CGRect {
                CGRect(x: (cropRect.minX + box.minX * CGFloat(crop.width)) / CGFloat(width),
                    y: (CGFloat(height) - cropRect.maxY + box.minY * CGFloat(crop.height)) / CGFloat(height),
                    width: box.width * CGFloat(crop.width) / CGFloat(width), height: box.height * CGFloat(crop.height) / CGFloat(height))
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return recognized.map { block in
                var mapped = block
                mapped.boundingBox = mappedBounds(block.boundingBox)
                mapped.scriptRuns = block.scriptRuns.map { run in
                    var global = run
                    global.boundingBox = mappedBounds(run.boundingBox)
                    return global
                }
                return mapped
            }
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
            var selected = languages.filter { supported.contains($0) && seen.insert($0).inserted }
            guard languages.isEmpty || !selected.isEmpty else {
                throw NSError(domain: "niko-shot.ocr", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "当前 macOS 不支持所选识别语言。"])
            }
            // CJK recognition also reads Latin text, whereas an English-first explicit
            // request can discard CJK. With Chinese and Japanese enabled, keep Han
            // recognition in the selected Chinese variant and extend kana separately.
            if request.recognitionLevel == .accurate,
               let primary = selected.first(where: { $0.hasPrefix("zh-") }) ??
                             selected.first(where: { $0.hasPrefix("ja-") || $0.hasPrefix("ko-") }) {
                selected = [primary] + selected.filter { $0 != primary }
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
            // Automatic detection can choose the Japanese model for a whole mixed
            // line and corrupt simplified Han. Honor enabled languages explicitly;
            // retain detection only when the caller has requested automatic language.
            request.automaticallyDetectsLanguage = configuration.languages.isEmpty
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).compactMap(nativeBlock)
        }
    }

    /// Copies native candidate geometry into Sendable values; Vision objects stay
    /// within the synchronous request's autorelease pool.
    nonisolated static func nativeBlock(_ observation: VNRecognizedTextObservation) -> OCRBlock? {
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let text = candidate.string
        let runs = cjkRuns(in: text).compactMap { range -> OCRScriptRun? in
            guard let rectangle = try? candidate.boundingBox(for: range),
                  rectangle.boundingBox.width > 0, rectangle.boundingBox.height > 0 else { return nil }
            return OCRScriptRun(range: range, boundingBox: rectangle.boundingBox, hasKana: text[range].contains(where: isKana))
        }
        return OCRBlock(text: text, boundingBox: observation.boundingBox, confidence: candidate.confidence, scriptRuns: runs)
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

    private nonisolated static func cjkRuns(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = [], start: String.Index?
        for index in text.indices {
            if isKana(text[index]) || isHan(text[index]) {
                if start == nil { start = index }
            } else if let beginning = start {
                ranges.append(beginning..<index)
                start = nil
            }
        }
        if let start { ranges.append(start..<text.endIndex) }
        return ranges
    }

    private nonisolated static func japaneseRuns(in text: String) -> [Range<String.Index>] {
        cjkRuns(in: text).filter { text[$0].contains(where: isKana) }
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
