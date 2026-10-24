// Presents native format selection without doing image encoding on the UI actor.
import AppKit

@MainActor
final class SavePanelRouter: NSObject {
    private let panel: NSSavePanel
    private let formatMenu = NSPopUpButton()
    private let quality = NSSlider(value: AppSettings.shared.jpegQuality, minValue: 0, maxValue: 1, target: nil, action: nil)
    init(panel: NSSavePanel = NSSavePanel()) { self.panel = panel; super.init() }
    /// Returns the chosen destination and encoder settings after a native save panel.
    func destination() -> (URL, ExportFormat, Double)? {
        for format in ExportFormat.allCases { formatMenu.addItem(withTitle: format.rawValue.uppercased()) }
        formatMenu.selectItem(at: ExportFormat.allCases.firstIndex(of: ExportFormat(rawValue: AppSettings.shared.exportFormatRaw) ?? .png) ?? 0)
        formatMenu.target = self; formatMenu.action = #selector(formatChanged)
        formatMenu.setAccessibilityLabel("保存格式"); quality.setAccessibilityLabel("JPEG 编码质量")
        let stack = NSStackView(views: [NSTextField(labelWithString: "格式"), formatMenu, NSTextField(labelWithString: "质量"), quality])
        stack.frame.size = CGSize(width: 400, height: 32)
        panel.accessoryView = stack; panel.canCreateDirectories = true
        let n = UserDefaults.standard.integer(forKey: "filenameSequence") + 1
        panel.nameFieldStringValue = Exporters.filename(template: AppSettings.shared.filenameTemplate, date: .now, sequence: n, format: selectedFormat)
        formatChanged()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, selectedFormat, quality.doubleValue)
    }
    /// Dismisses an outstanding save panel so application termination can drain its output task.
    func cancel() { panel.cancel(nil) }
    private var selectedFormat: ExportFormat { ExportFormat.allCases[max(0, formatMenu.indexOfSelectedItem)] }
    @objc private func formatChanged() {
        panel.allowedContentTypes = [selectedFormat.type]
        quality.isEnabled = selectedFormat == .jpeg || selectedFormat == .heif
        panel.nameFieldStringValue = Self.name(panel.nameFieldStringValue, withExtensionOf: selectedFormat)
    }
    /// Swaps only a known image extension, so a typed name (even one with dots in it) survives a format change.
    nonisolated static func name(_ name: String, withExtensionOf format: ExportFormat) -> String {
        let known: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff"]
        let ext = (name as NSString).pathExtension
        let stem = known.contains(ext.lowercased()) ? (name as NSString).deletingPathExtension : name
        return (stem.isEmpty ? "niko-shot" : stem) + "." + format.fileExtension
    }
}
