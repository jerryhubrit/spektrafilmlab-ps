import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Adapted from SpektraLab ImageDecoder.swift (GPL-3.0). Two looks, one
// geometry: scene-linear sensor response for film; Apple's look for compare.
final class RAWSource {
    let id = UUID().uuidString
    let url: URL
    var linear: CIRAWFilter, display: CIRAWFilter
    let temperature: Float, tint: Float, lensSupported: Bool
    var key = "", previewKey = "", original = ""
    var customWB = false
    var crop: [String: Double]?
    var imprint: [String: Any] = [:]
    init(path: String) throws {
        let extensions: Set<String> = ["nef", "arw", "dng", "cr2", "cr3", "raf", "rw2", "orf", "pef", "srw", "3fr", "iiq"]
        url = URL(fileURLWithPath: path).standardizedFileURL
        guard extensions.contains(url.pathExtension.lowercased()),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let a = CIRAWFilter(imageURL: url), let b = CIRAWFilter(imageURL: url) else {
            throw fail("无法读取此 RAW；请确认文件完整，且当前 macOS 支持该相机。")
        }
        linear = a; display = b
        temperature = b.neutralTemperature; tint = b.neutralTint
        lensSupported = b.isLensCorrectionSupported
        guard let image = b.outputImage else { throw fail("当前 macOS 无法解码这个 RAW 文件。") }
        guard image.extent.width * image.extent.height <= 50_000_000 else {
            throw fail("当前版本支持不超过 5000 万像素的 RAW。")
        }
        imprint = Self.readImprint(url)
    }
    func configure(_ settings: [String: Any]) throws {
        if let c = settings["crop"] as? [String: Double] {
            guard let aspect = c["aspect"], aspect.isFinite, (0.1...10).contains(aspect),
                  let x = c["x"], let y = c["y"], (0...1).contains(x), (0...1).contains(y) else { throw fail("片边构图参数无效。") }
            crop = c
        } else { crop = nil }
        let t = (settings["temperature"] as? NSNumber)?.floatValue
        let n = (settings["tint"] as? NSNumber)?.floatValue
        guard t == nil || (t!.isFinite && (2000...12000).contains(t!)),
              n == nil || (n!.isFinite && (-150...150).contains(n!)) else { throw fail("白平衡参数超出范围。") }
        let custom = t != nil || n != nil
        // Never assign reported camera values to restore as-shot: that activates
        // an override and is not the same as the untouched camera WB transform.
        if customWB && !custom {
            guard let a = CIRAWFilter(imageURL: url), let b = CIRAWFilter(imageURL: url) else { throw fail("RAW 重新解码失败。") }
            linear = a; display = b
        }
        customWB = custom
        for f in [linear, display] {
            f.isLensCorrectionEnabled = (settings["lensCorrection"] as? Bool ?? false) && lensSupported
            f.isDraftModeEnabled = false
            if custom { f.neutralTemperature = t ?? temperature; f.neutralTint = n ?? tint }
        }
        linear.boostAmount = 0; linear.boostShadowAmount = 0
        linear.isGamutMappingEnabled = false
        linear.localToneMapAmount = 0; linear.extendedDynamicRangeAmount = 0
        key = String(data: jsonData(settings), encoding: .utf8)!
    }
    static let space: CGColorSpace = {
        var white: [CGFloat] = [0.9642, 1, 0.8249], black: [CGFloat] = [0, 0, 0], gamma: [CGFloat] = [1, 1, 1]
        var matrix: [CGFloat] = [0.7976749,0.2880402,0, 0.1351917,0.7118741,0, 0.0313534,0.0000857,0.8252100]
        return CGColorSpace(calibratedRGBWhitePoint: &white, blackPoint: &black, gamma: &gamma, matrix: &matrix)!
    }()
    func image(_ filter: CIRAWFilter, small: Bool) throws -> CIImage {
        guard var image = filter.outputImage else { throw fail("RAW 解码没有输出图像。") }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let crop {
            let aspect = crop["aspect"]!, w = image.extent.width, h = image.extent.height
            let cw = min(w, h * aspect), ch = min(h, w / aspect)
            let box = CGRect(x: floor((w - cw) * crop["x"]!), y: floor((h - ch) * (1 - crop["y"]!)), width: floor(cw), height: floor(ch))
            image = image.cropped(to: box).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
        }
        let scale = small ? min(1, 1024 / max(image.extent.width, image.extent.height)) : 1
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        return image.cropped(to: CGRect(x: 0, y: 0, width: floor(image.extent.width), height: floor(image.extent.height)))
    }
    // Only fields the original date back actually prints; never return the
    // complete EXIF dictionary, GPS, camera serial or owner information.
    static func readImprint(_ url: URL) -> [String: Any] {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return [:] }
        var result: [String: Any] = [:], fields: [String] = []
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let p = date.prefix(10).split(separator: ":").compactMap { Int($0) }
            if p.count == 3, p[0] > 1800, (1...12).contains(p[1]), (1...31).contains(p[2]) {
                result["captureDate"] = String(format: "%04d-%02d-%02d", p[0], p[1], p[2])
            }
        }
        func positive(_ key: CFString) -> Double? {
            guard let n = exif[key] as? NSNumber, n.doubleValue.isFinite, n.doubleValue > 0 else { return nil }
            return n.doubleValue
        }
        func trimmed(_ n: Double) -> String {
            let s = String(format: "%.1f", n); return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        }
        if let t = positive(kCGImagePropertyExifExposureTime) { fields.append(t >= 1 ? trimmed(t) + "s" : "1/\(Int((1 / t).rounded()))") }
        if let f = positive(kCGImagePropertyExifFNumber) { result["fNumber"] = min(64, f); fields.append("F" + trimmed(f)) }
        if let p = (exif[kCGImagePropertyExifExposureProgram] as? NSNumber)?.intValue, let mode = [1:"M", 2:"P", 3:"A", 4:"S"][p] { fields.append(mode) }
        if let ev = (exif[kCGImagePropertyExifExposureBiasValue] as? NSNumber)?.doubleValue, ev.isFinite, (ev * 10).rounded() != 0 { fields.append(String(format: "%+.1f", ev)) }
        if let mm = positive(kCGImagePropertyExifFocalLenIn35mmFilm) { fields.append("\(Int(mm.rounded()))mm") }
        while fields.joined(separator: " ").count > 22 { fields.removeLast() }
        result["shootingText"] = fields.joined(separator: " ")
        return result
    }
}

extension FilmEngine {
    func latitude(_ request: Request) throws -> Data {
        let input = try object(request.body)
        guard let source = raw, input["sourceId"] as? String == source.id,
              let frame = preview, frame.linear, source.previewKey == source.key else {
            throw fail("请先等待当前 RAW 预览完成。")
        }
        let settings = input["placement"] as? [String: Any] ?? [:]
        var reply: UnsafeMutablePointer<CChar>?
        try checked(spk_scene_latitude(frame.session, String(data: jsonData(settings), encoding: .utf8), &reply))
        guard let reply else { throw fail("场景宽容度分析没有返回结果。") }
        defer { spk_string_free(reply) }
        return Data(String(cString: reply).utf8)
    }
    func openRAW(_ request: Request) throws -> Data {
        let input = try object(request.body)
        guard let path = input["path"] as? String, path.hasPrefix("/") else { throw fail("请选择本机 RAW 文件。") }
        // Invalidate old handles even when a new RAW fails to decode.
        preview = nil; full = nil; raw = nil
        let source = try RAWSource(path: path)
        try source.configure([:])
        let image = try source.image(source.linear, small: false)
        raw = source
        return jsonData(["sourceId": source.id, "name": source.url.deletingPathExtension().lastPathComponent,
                         "width": Int(image.extent.width), "height": Int(image.extent.height),
                         "temperature": source.temperature, "tint": source.tint, "lensSupported": source.lensSupported, "imprint": source.imprint])
    }
    func rawFrame(_ source: RAWSource, small: Bool, requested: [String: Any]) throws -> Frame {
        let image = try source.image(source.linear, small: small)
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard w > 0, h > 0, w * h <= 50_000_000 else { throw fail("RAW 尺寸不支持。") }
        let initial = try params(requested, linear: true)
        var pixels = [Float](repeating: 0, count: w * h * 4)
        var reply: UnsafeMutablePointer<CChar>?
        let session = pixels.withUnsafeMutableBytes { buffer -> OpaquePointer? in
            ci.render(image, toBitmap: buffer.baseAddress!, rowBytes: w * 16, bounds: image.extent, format: .RGBAf, colorSpace: RAWSource.space)
            var input = spk_image(data: buffer.bindMemory(to: Float.self).baseAddress, width: UInt32(w), height: UInt32(h), channels: 4)
            return spk_open(handle, &input, String(data: jsonData(initial), encoding: .utf8), &reply)
        }
        if let reply { spk_string_free(reply) }
        guard let session else { throw fail(String(cString: spk_last_error(handle))) }
        let frame = Frame(session: session, width: w, height: h, alpha: nil)
        frame.linear = true; frame.sent = initial
        return frame
    }
    func renderRAW(_ request: Request) throws -> Response {
        let input = try object(request.body)
        guard let source = raw, input["sourceId"] as? String == source.id,
              let requested = input["params"] as? [String: Any],
              let decode = input["decode"] as? [String: Any] else { throw fail("RAW 已失效，请重新打开。") }
        let small = input["full"] as? Bool != true
        let started = Date()
        try source.configure(decode)
        let frame: Frame
        if small, source.previewKey == source.key, let cached = preview, cached.linear {
            frame = cached
        } else {
            if small { preview = nil } else { full = nil }
            frame = try rawFrame(source, small: small, requested: requested)
            if small {
                preview = frame; source.previewKey = source.key
                let image = try source.image(source.display, small: true)
                guard let data = ci.pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw fail("原图预览生成失败。") }
                source.original = "data:image/png;base64," + data.base64EncodedString()
            } else { full = frame }
        }
        let response = try render(Request(method: "POST", path: "/render", query: [:], headers: [:], body: jsonData(["sourceId": frame.id, "params": requested])))
        if !small { return response }
        return Response(body: jsonData(["image": "data:image/png;base64," + response.body.base64EncodedString(), "original": source.original,
                                        "width": Int(response.headers["X-Width"]!)!, "height": Int(response.headers["X-Height"]!)!, "ms": Int(Date().timeIntervalSince(started) * 1000)]))
    }
}
