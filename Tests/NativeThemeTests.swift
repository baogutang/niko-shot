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
        light: [0.965, 0.960, 0.949, 1], dark: [0.095, 0.099, 0.108, 1]),
      ThemeSwatch(name: "surface", color: NikoTheme.surface,
        light: [1.000, 0.997, 0.987, 1], dark: [0.135, 0.140, 0.150, 1]),
      ThemeSwatch(name: "raisedSurface", color: NikoTheme.raisedSurface,
        light: [0.945, 0.937, 0.923, 1], dark: [0.175, 0.180, 0.190, 1]),
      ThemeSwatch(name: "accent", color: NikoTheme.accent,
        light: [0.620, 0.380, 0.105, 1], dark: [0.955, 0.705, 0.365, 1]),
      ThemeSwatch(name: "onAccent", color: NikoTheme.onAccent,
        light: [1, 1, 1, 1], dark: [0.115, 0.100, 0.075, 1]),
      ThemeSwatch(name: "selection", color: NikoTheme.selection,
        light: [0.620, 0.380, 0.105, 0.12], dark: [0.955, 0.705, 0.365, 0.12]),
      ThemeSwatch(name: "separator", color: NikoTheme.separator, light: nil, dark: nil)
    ]
    let samples = await Task.detached { @Sendable in Self.resolve(swatches) }.value
    XCTAssertEqual(samples.count, swatches.count * 6)
    for sample in samples {
      let context = "\(sample.name), dark=\(sample.dark), increasedContrast=\(sample.increasedContrast)"
      XCTAssertTrue(sample.isBackgroundThread, "Must exercise a real background resolver: \(context)")
      XCTAssertEqual(sample.components.count, 4, context)
      XCTAssertTrue(sample.components.allSatisfy { $0.isFinite && (0...1).contains($0) }, context)
      if let swatch = swatches.first(where: { $0.name == sample.name }),
        let expected = sample.dark ? swatch.dark : swatch.light
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
        results.append(ThemeResolution(name: swatch.name, dark: dark,
          increasedContrast: false, isBackgroundThread: isBackgroundThread,
          components: [Double(value.red), Double(value.green), Double(value.blue), Double(value.opacity)]))
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
              components: [value.redComponent, value.greenComponent, value.blueComponent, value.alphaComponent]))
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

private struct ThemeResolution: Sendable {
  let name: String
  let dark: Bool
  let increasedContrast: Bool
  let isBackgroundThread: Bool
  let components: [Double]
}
