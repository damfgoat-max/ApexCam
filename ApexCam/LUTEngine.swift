import Foundation
import CoreImage
import UIKit

// MARK: - LUT engine (v4)
// The photo version of Blackmagic Camera's LUT workflow: import .cube files,
// pick a look, see it live, and bake it into the saved photo. All cube data is
// built on background queues; nothing here runs in a SwiftUI view body.

struct CubeLUT {
    let name: String
    let dimension: Int
    /// Flat RGB triples in .cube order (red fastest, then green, then blue) —
    /// the same order CIColorCube expects.
    let rgb: [Float]

    /// RGBA float data for CIColorCube at a given strength (0...1), where the
    /// look is blended over the identity. Strength is baked into the cube so a
    /// single CIColorCube pass produces the blended result.
    func cubeData(strength: Double) -> Data {
        let s = Float(min(max(strength, 0), 1))
        let n = dimension
        var floats = [Float]()
        floats.reserveCapacity(n * n * n * 4)
        var idx = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let ir = Float(r) / Float(n - 1)
                    let ig = Float(g) / Float(n - 1)
                    let ib = Float(b) / Float(n - 1)
                    let lr = rgb[idx], lg = rgb[idx + 1], lb = rgb[idx + 2]
                    idx += 3
                    floats.append(ir + (lr - ir) * s)
                    floats.append(ig + (lg - ig) * s)
                    floats.append(ib + (lb - ib) * s)
                    floats.append(1)
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

enum LUTEngine {

    // MARK: .cube parsing
    /// Parses a .cube file: LUT_3D_SIZE (17/32/33/64), TITLE, DOMAIN_* and
    /// comment lines are handled/ignored; data lines are "r g b" floats.
    /// Returns nil if the data doesn't add up to size^3 RGB triples.
    static func parseCube(data: Data, fallbackName: String) -> CubeLUT? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else { return nil }
        var declaredSize: Int? = nil
        var title: String? = nil
        var values: [Float] = []
        values.reserveCapacity(33 * 33 * 33 * 3)
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("LUT_3D_SIZE") {
                declaredSize = line.split(separator: " ").last.flatMap { Int($0) }
                continue
            }
            if line.hasPrefix("TITLE") {
                title = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                continue
            }
            if line.hasPrefix("DOMAIN_") || line.hasPrefix("LUT_1D") || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) {
                values.append(r); values.append(g); values.append(b)
            }
        }
        let size: Int
        if let d = declaredSize, [17, 32, 33, 64].contains(d), values.count == d * d * d * 3 {
            size = d
        } else if let found = [17, 32, 33, 64].first(where: { values.count == $0 * $0 * $0 * 3 }) {
            size = found
        } else {
            return nil
        }
        let name = (title?.isEmpty == false ? title! : fallbackName)
        return CubeLUT(name: name, dimension: size, rgb: values)
    }

    // MARK: Built-in looks — generated programmatically, no embedded files.
    static let builtInDimension = 32
    static let builtInNames = ["None", "Warm Golden Hour", "Teal & Orange", "Kodak Film", "Soft Portrait", "Classic B&W"]

    static func builtIn(_ name: String) -> CubeLUT? {
        guard builtInNames.contains(name), name != "None" else { return nil }
        let transform: (Double, Double, Double) -> (Double, Double, Double)
        switch name {
        case "Warm Golden Hour": transform = warmGoldenHour
        case "Teal & Orange": transform = tealAndOrange
        case "Kodak Film": transform = kodakFilm
        case "Soft Portrait": transform = softPortrait
        case "Classic B&W": transform = classicBW
        default: return nil
        }
        let n = builtInDimension
        var rgb = [Float]()
        rgb.reserveCapacity(n * n * n * 3)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let out = transform(Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1))
                    rgb.append(Float(clamp01(out.0))); rgb.append(Float(clamp01(out.1))); rgb.append(Float(clamp01(out.2)))
                }
            }
        }
        return CubeLUT(name: name, dimension: n, rgb: rgb)
    }

    // MARK: CIColorCube application
    static func colorCube(_ image: CIImage, cubeData: Data, dimension: Int) -> CIImage {
        guard let f = CIFilter(name: "CIColorCube") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(dimension, forKey: "inputCubeDimension")
        f.setValue(cubeData, forKey: "inputCubeData")
        return f.outputImage ?? image
    }

    /// Grades photo file data (JPEG/HEIF) and returns JPEG data, preserving the
    /// photo's orientation by baking it into the pixels. Runs on the caller's
    /// (background) queue. Returns nil on any failure — callers fall back to
    /// the original data.
    static func gradePhotoData(_ data: Data, cubeData: Data, dimension: Int, context: CIContext) -> Data? {
        guard var ci = CIImage(data: data) else { return nil }
        // Bake EXIF orientation into the pixels so the re-encoded JPEG (which
        // carries no orientation tag) displays upright.
        if let o = (ci.properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value, o != 1 {
            ci = ci.oriented(forExifOrientation: o)
        }
        let graded = colorCube(ci, cubeData: cubeData, dimension: dimension)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return context.jpegRepresentation(of: graded, colorSpace: space, options: [:])
    }

    // MARK: - Per-look color transforms (input/output are linear-ish 0...1 RGB)

    private static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
    private static func lum(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    private static func saturate(_ r: Double, _ g: Double, _ b: Double, _ s: Double) -> (Double, Double, Double) {
        let l = lum(r, g, b)
        return (l + (r - l) * s, l + (g - l) * s, l + (b - l) * s)
    }
    /// Gentle S-curve: amount 0 = identity, ~0.25 = firm contrast.
    private static func softCurve(_ x: Double, _ amount: Double) -> Double {
        // Simple photographic contrast blend toward a smoothstep.
        let smooth = x * x * (3 - 2 * x)
        return clamp01(x * (1 - amount) + smooth * amount)
    }

    /// Warm amber shadows, golden mids, creamy highlights, blues slightly
    /// suppressed — the user's favourite San Diego golden-hour look.
    private static func warmGoldenHour(_ r0: Double, _ g0: Double, _ b0: Double) -> (Double, Double, Double) {
        var (r, g, b) = (r0, g0, b0)
        // Warm white-balance nudge.
        r *= 1.05; b *= 0.92
        let l = lum(r, g, b)
        // Amber split-tone: shadows toward amber-brown, highlights creamy yellow.
        let shadowW = (1 - l) * (1 - l)
        let highW = l * l
        r += 0.055 * shadowW; g += 0.028 * shadowW; b -= 0.040 * shadowW
        r += 0.035 * highW; g += 0.018 * highW; b -= 0.030 * highW
        // Suppress dominant blues (sky/water) so they don't fight the warmth.
        if b > r && b > g {
            let l2 = lum(r, g, b)
            b = b + (l2 - b) * 0.25
        }
        (r, g, b) = saturate(r, g, b, 1.06)
        // Soft contrast with slightly lifted blacks (creamy, not crunchy).
        r = softCurve(r, 0.18) * 0.97 + 0.018
        g = softCurve(g, 0.18) * 0.97 + 0.018
        b = softCurve(b, 0.18) * 0.97 + 0.018
        return (r, g, b)
    }

    /// Teal shadows, warm protected skin — the sports/Hollywood split.
    private static func tealAndOrange(_ r0: Double, _ g0: Double, _ b0: Double) -> (Double, Double, Double) {
        var (r, g, b) = (r0, g0, b0)
        let l = lum(r, g, b)
        let shadowW = (1 - l) * (1 - l)
        let highW = l * l
        // Teal into the shadows, a little warmth into the highlights.
        r -= 0.030 * shadowW; g += 0.045 * shadowW; b += 0.055 * shadowW
        r += 0.028 * highW; g += 0.008 * highW; b -= 0.025 * highW
        (r, g, b) = saturate(r, g, b, 1.08)
        // Skin protection: warm, red-dominant mid-tones get a gentle warm
        // saturation hold instead of being pushed teal.
        if r > g && g >= b && l > 0.15 && l < 0.85 {
            (r, g, b) = saturate(r, g, b, 1.05)
            r *= 1.02
        }
        r = softCurve(r, 0.22); g = softCurve(g, 0.22); b = softCurve(b, 0.22)
        return (r, g, b)
    }

    /// Dense blacks, firm contrast, warm highlights — print-film character.
    private static func kodakFilm(_ r0: Double, _ g0: Double, _ b0: Double) -> (Double, Double, Double) {
        // Black crush toward dense blacks, then a firm S-curve.
        func filmCurve(_ x: Double) -> Double {
            let crushed = clamp01((x - 0.035) / 0.965)
            return softCurve(crushed, 0.38)
        }
        var (r, g, b) = (filmCurve(r0), filmCurve(g0), filmCurve(b0))
        let l = lum(r, g, b)
        if l > 0.55 { // warm highlights
            let w = (l - 0.55) / 0.45
            r *= 1 + 0.04 * w; b *= 1 - 0.09 * w
        }
        (r, g, b) = saturate(r, g, b, 0.95)
        return (r, g, b)
    }

    /// Gentle contrast, warm mids, protected highlights — flattering people look.
    private static func softPortrait(_ r0: Double, _ g0: Double, _ b0: Double) -> (Double, Double, Double) {
        var (r, g, b) = (r0, g0, b0)
        // Warm the mid-tones.
        let l = lum(r, g, b)
        let midW = max(0, 1 - abs(l - 0.5) * 2)
        r *= 1 + 0.03 * midW; b *= 1 - 0.045 * midW
        (r, g, b) = saturate(r, g, b, 0.98)
        // Gentle contrast, lifted blacks, soft highlight roll-off.
        func gentle(_ x: Double) -> Double {
            var v = softCurve(x, 0.10) * 0.94 + 0.035
            if v > 0.85 { v = 0.85 + (v - 0.85) * 0.6 }
            return clamp01(v)
        }
        return (gentle(r), gentle(g), gentle(b))
    }

    private static func classicBW(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let l = softCurve(lum(r, g, b), 0.25)
        return (l, l, l)
    }
}
