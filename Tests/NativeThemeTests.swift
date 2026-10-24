// Resolves the real adaptive palette on drawing threads without creating application windows.
import AppKit
import SwiftUI
import XCTest
@testable import NikoShot

@MainActor
final class NativeThemeTests: XCTestCase {
  func testCaptureChromeUsesTheIconAmberInEveryAppearance() throws {
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      let appearance = try XCTUnwrap(NSAppearance(named: name))
      appearance.performAsCurrentDrawingAppearance {
        let color = CaptureChrome.accent.usingColorSpace(.sRGB)
        XCTAssertEqual(color?.redComponent ?? 0, 0.909804, accuracy: 0.0001)
        XCTAssertEqual(color?.greenComponent ?? 0, 0.639216, accuracy: 0.0001)
      }
    }
  }

  func testEntirePaletteResolvesOffMainWithLightDarkAndIncreasedContrast() async {
    let amberLight: [Double] = [0.678431, 0.443137, 0.066667, 1], amberDark: [Double] = [0.909804, 0.639216, 0.2, 1]
    let ink: [Double] = [0.109804, 0.090196, 0.062745, 1]
    // System surfaces only need to resolve off main; their values belong to macOS.
    let swatches: [ThemeSwatch] = [
      ThemeSwatch(name: "canvas", color: NikoTheme.canvas, light: nil, dark: nil),
      ThemeSwatch(name: "surface", color: NikoTheme.surface, light: nil, dark: nil),
      ThemeSwatch(name: "raisedSurface", color: NikoTheme.raisedSurface, light: nil, dark: nil),
      ThemeSwatch(name: "accent", color: NikoTheme.accent, light: amberLight, dark: amberDark),
      ThemeSwatch(name: "onAccent", color: NikoTheme.onAccent, light: ink, dark: ink),
      ThemeSwatch(name: "selection", color: NikoTheme.selection,
        light: Array(amberLight.prefix(3)) + [0.14], dark: Array(amberDark.prefix(3)) + [0.14]),
      ThemeSwatch(name: "separator", color: NikoTheme.separator, light: nil, dark: nil),
      ThemeSwatch(name: "translation", color: NikoTheme.translation, light: nil, dark: nil),
      ThemeSwatch(name: "seal", color: NikoTheme.seal, light: nil, dark: nil)
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
