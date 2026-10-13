// Edits plain text through AppKit without a SwiftUI accessibility-label wrapper.
import AppKit
import SwiftUI

/// A native multiline editor that preserves marked text and labels its NSTextView directly.
@MainActor
public struct NativeTextEditor: NSViewRepresentable {
  @Binding private var text: String
  private let accessibilityLabel: String
  private let isEditable: Bool

  /// Binds plain text to a transparent editor with an independent native accessibility label.
  public init(
    text: Binding<String>, accessibilityLabel: String, isEditable: Bool = true
  ) {
    self._text = text
    self.accessibilityLabel = accessibilityLabel
    self.isEditable = isEditable
  }

  /// Creates the delegate that forwards native text changes to the current binding.
  public func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  /// Creates a scrollable system-font editor with native selection and undo support.
  public func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView(frame: .zero)
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true

    let textView = NSTextView(frame: .zero)
    textView.isRichText = false
    textView.importsGraphics = false
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.font = .systemFont(ofSize: 13)
    textView.textColor = .labelColor
    textView.insertionPointColor = .labelColor
    textView.isEditable = isEditable
    textView.isSelectable = true
    textView.allowsUndo = true
    textView.usesFontPanel = false
    textView.usesRuler = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = .zero
    textView.maxSize = CGSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainerInset = CGSize(width: 0, height: 4)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.string = text
    textView.setAccessibilityLabel(accessibilityLabel)
    textView.delegate = context.coordinator
    scrollView.documentView = textView
    return scrollView
  }

  /// Applies external text changes after composition, retaining selections within UTF-16 bounds.
  public func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.text = $text
    guard let textView = scrollView.documentView as? NSTextView else { return }
    textView.setAccessibilityLabel(accessibilityLabel)
    textView.isEditable = isEditable
    guard !textView.hasMarkedText(), textView.string != text else { return }

    let selections = textView.selectedRanges
    context.coordinator.isApplyingExternalChange = true
    textView.string = text
    let length = (text as NSString).length
    textView.selectedRanges = selections.map { value in
      let range = value.rangeValue
      let location = range.location == NSNotFound ? length : min(range.location, length)
      return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
    }
    context.coordinator.isApplyingExternalChange = false
  }

  /// Disconnects the native delegate and document when the SwiftUI editor is removed.
  public static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    (scrollView.documentView as? NSTextView)?.delegate = nil
    scrollView.documentView = nil
  }

  /// Bridges native edit notifications without installing observers or accessibility overrides.
  @MainActor
  public final class Coordinator: NSObject, NSTextViewDelegate {
    fileprivate var text: Binding<String>
    fileprivate var isApplyingExternalChange = false

    fileprivate init(text: Binding<String>) { self.text = text }

    /// Publishes native edits, including IME composition, without resetting the native text storage.
    public func textDidChange(_ notification: Notification) {
      guard !isApplyingExternalChange,
        let textView = notification.object as? NSTextView,
        text.wrappedValue != textView.string
      else { return }
      text.wrappedValue = textView.string
    }
  }
}
