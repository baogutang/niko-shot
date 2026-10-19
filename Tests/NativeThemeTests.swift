// Resolves the real adaptive palette on drawing threads without creating application windows.
import AppKit
import SwiftUI
import XCTest
@testable import NikoShot

@MainActor
final class NativeThemeTests: XCTestCase {
  func testEntirePaletteResolvesOffMainWithLightDarkAndIncreasedContrast() async {
    let swatches: [ThemeSwatch] = [
      ThemeSwatch(name: "canvas", color: NikoTheme.canvas,
        light: [0.952941, 0.929412, 0.886275, 1], dark: [0.070588, 0.078431, 0.090196, 1]),
      ThemeSwatch(name: "surface", color: NikoTheme.surface,
        light: [0.984314, 0.972549, 0.949020, 1], dark: [0.117647, 0.133333, 0.149020, 1]),
      ThemeSwatch(name: "raisedSurface", color: NikoTheme.raisedSurface,
        light: [1.0, 0.992157, 0.968627, 1], dark: [0.149020, 0.168627, 0.188235, 1]),
      ThemeSwatch(name: "accent", color: NikoTheme.accent,
        light: [0.784314, 0.250980, 0.184314, 1], dark: [0.949020, 0.701961, 0.239216, 1]),
      ThemeSwatch(name: "onAccent", color: NikoTheme.onAccent,
        light: [0.992157, 0.968627, 0.941176, 1], dark: [0.133333, 0.094118, 0.015686, 1]),
      ThemeSwatch(name: "selection", color: NikoTheme.selection,
        light: [0.784314, 0.250980, 0.184314, 0.12], dark: [0.949020, 0.701961, 0.239216, 0.12]),
      ThemeSwatch(name: "separator", color: NikoTheme.separator,
        light: [0.886275, 0.850980, 0.776471, 1], dark: [0.164706, 0.176471, 0.196078, 1]),
      ThemeSwatch(name: "translation", color: NikoTheme.translation,
        light: [0.184314, 0.364706, 0.384314, 1], dark: [0.372549, 0.701961, 0.631373, 1]),
      ThemeSwatch(name: "seal", color: NikoTheme.seal,
        light: [0.784314, 0.250980, 0.184314, 1], dark: [0.807843, 0.207843, 0.152941, 1])
    ]
    let samples = await Task.detached { @Sendable in Self.resolve(swatches) }.value
    XCTAssertEqual(samples.count, swatches.count * 6)
    for sample in samples {
      let context = "\(sample.name), dark=\(sample.dark), increasedContrast=\(sample.increasedContrast)"
      XCTAssertTrue(sample.isBackgroundThread, "Must exercise a real background resolver: \(context)")
      XCTAssertEqual(sample.components.count, 4, context)
      XCTAssertTrue(sample.components.allSatisfy { $0.isFinite && (0...1).contains($0) }, context)
      if let swatch = swatches.first(where: { $0.name == sample.name }),
        let expected = sample.systemComponents ?? (sample.dark ? swatch.dark : swatch.light)
      {
        for (actual, expectedComponent) in zip(sample.components, expected) {
          XCTAssertEqual(actual, expectedComponent, accuracy: 0.00001, context)
        }
      }
    }
  }

  private nonisolated static func resolve(_ swatches: [ThemeSwatch]) -> [ThemeResolution] {
    let isBackgroundThread = !Thread.isMainThread
    var results: [ThemeResolution] = []
    for dark in [false, true] {
      var environment = EnvironmentValues()
      environment.colorScheme = dark ? .dark : .light
      for swatch in swatches {
        // SwiftUI's public resolver invokes the underlying AppKit provider on this drawing thread.
        let value = swatch.color.resolve(in: environment)
        let expected = sampleExpected(swatch, dark: dark, opacity: value.opacity)
        results.append(ThemeResolution(name: swatch.name, dark: dark,
          increasedContrast: false, isBackgroundThread: isBackgroundThread,
          components: [Double(value.red), Double(value.green), Double(value.blue), Double(value.opacity)],
          systemComponents: expected))
      }
      for increased in [false, true] {
        let name: NSAppearance.Name = dark
          ? (increased ? .accessibilityHighContrastDarkAqua : .darkAqua)
          : (increased ? .accessibilityHighContrastAqua : .aqua)
        guard let appearance = NSAppearance(named: name) else { continue }
        appearance.performAsCurrentDrawingAppearance {
          for swatch in swatches {
            guard let value = NSColor(swatch.color).usingColorSpace(.sRGB) else { continue }
            results.append(ThemeResolution(name: swatch.name, dark: dark,
              increasedContrast: increased, isBackgroundThread: isBackgroundThread,
              components: [value.redComponent, value.greenComponent, value.blueComponent, value.alphaComponent],
              systemComponents: nil))
          }
        }
      }
    }
    return results
  }
}

private struct ThemeSwatch: Sendable {
  let name: String
  let color: Color
  let light: [Double]?
  let dark: [Double]?
}

private nonisolated func sampleExpected(_ swatch: ThemeSwatch, dark: Bool, opacity: Float) -> [Double]? {
  guard var components = dark ? swatch.dark : swatch.light else { return nil }
  if components.count == 4 { components[3] = Double(opacity) }
  return components
}

private struct ThemeResolution: Sendable {
  let name: String
  let dark: Bool
  let increasedContrast: Bool
  let isBackgroundThread: Bool
  let components: [Double]
  let systemComponents: [Double]?
}
