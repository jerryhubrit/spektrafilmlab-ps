import Foundation
import Network
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
import CoreImage
import Metal

struct Failure: Error { let message: String }
func fail(_ message: String) -> Failure { Failure(message: message) }
func jsonData(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data() }
func object(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw fail("Expected JSON object") }
    return value
}

final class Frame {
    let id = UUID().uuidString
    let session: OpaquePointer
    let width: Int, height: Int
    let alpha: [UInt16]?
    var sent: [String: Any] = [:]
    var linear = false
    init(session: OpaquePointer, width: Int, height: Int, alpha: [UInt16]?) {
        self.session = session; self.width = width; self.height = height; self.alpha = alpha
    }
    deinit { spk_session_release(session) }
}

final class FilmEngine {
    let handle: OpaquePointer
    var preview: Frame?, full: Frame?
    var raw: RAWSource?
    let ci = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    let catalog: [[String: String]]
    init(resources: String) throws {
        guard let h = spk_engine_create(resources, nil) else { throw fail("Metal engine initialization failed") }
        handle = h
        let folder = URL(fileURLWithPath: resources).appendingPathComponent("profiles")
        catalog = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { url in
                // Profile measurement arrays contain NaN; use JSON5-compatible
                // source extraction of just the info object, not the measurements.
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let start = text.range(of: "\"info\": {"),
                      let end = text[start.upperBound...].firstIndex(of: "}") else { return nil }
                let infoText = "{" + text[start.upperBound..<end] + "}"
                guard let info = try? object(Data(infoText.utf8)),
                      let stock = info["stock"] as? String,
                      let name = info["name"] as? String,
                      let stage = info["stage"] as? String else { return nil }
                return ["id": stock, "name": name, "stage": stage,
                        "type": info["type"] as? String ?? "",
                        "target": info["target_print"] as? String ?? ""]
            }.sorted { $0["name"]! < $1["name"]! }
    }
    deinit { preview = nil; full = nil; spk_engine_destroy(handle) }
    func checked(_ status: Int32) throws {
        if status != SPK_OK { throw fail(String(cString: spk_last_error(handle))) }
    }
    func params(_ requested: [String: Any], linear: Bool = false) throws -> [String: Any] {
        let allowed: Set<String> = ["film_stock", "print_stock", "exposure_compensation_ev", "print_exposure", "m_filter_shift", "y_filter_shift", "grain_amount", "grain_active", "halation_amount", "halation_active", "film_format_mm", "auto_exposure", "auto_exposure_method", "halation_scatter_amount", "glare_active", "glare_amount", "dir_couplers_active", "dir_couplers_amount", "scene_latitude_active", "scene_latitude_norm", "scene_latitude_highlight_knee", "scene_latitude_highlight_room", "scene_latitude_shadow_knee", "scene_latitude_shadow_room", "scene_latitude_rolloff", "scene_latitude_max_lift",
          "overscan_active", "overscan_format", "overscan_mode", "overscan_gate", "overscan_holes", "overscan_carrier", "overscan_camera_seed", "overscan_frame_seed", "overscan_frame_number", "overscan_fog", "overscan_leaks", "overscan_edge_text", "overscan_f_number",
          "date_imprint_active", "date_imprint_text", "date_imprint_data_text", "date_imprint_style", "date_imprint_placement", "date_imprint_corner", "date_imprint_size", "date_imprint_ev", "date_imprint_inset_x", "date_imprint_inset_y"]
        guard Set(requested.keys).isSubset(of: allowed) else { throw fail("Unsupported control") }
        var p = requested
        p["input_color_space"] = "ProPhoto RGB"
        p["input_cctf_decoding"] = !linear
        p["output_color_space"] = "ProPhoto RGB"
        p["output_cctf_encoding"] = true
        if p["auto_exposure"] == nil { p["auto_exposure"] = false }
        if p["glare_active"] == nil { p["glare_active"] = false }
        if p["overscan_active"] == nil { p["overscan_active"] = false }
        if p["date_imprint_active"] == nil { p["date_imprint_active"] = false }
        p["preview_long_edge"] = 1024
        return p
    }
    func source(_ request: Request) throws -> Data {
        guard let w = Int(request.query["width"] ?? ""), let h = Int(request.query["height"] ?? ""),
              let c = Int(request.query["channels"] ?? ""), w > 0, h > 0, w <= 20000, h <= 20000,
              w * h <= 50_000_000, c == 3 || c == 4,
              request.body.count == w * h * c * 2 else { throw fail("Invalid image size, channels, or byte count (max 50 MP)") }
        let isPreview = request.query["kind"] == "preview"
        if isPreview && max(w, h) > 1600 { throw fail("Preview exceeds 1600 pixels") }
        if isPreview { preview = nil } else { full = nil }
        var pixels = [Float](repeating: 0, count: w * h * 3)
        var alpha: [UInt16]? = c == 4 ? [UInt16](repeating: 65535, count: w * h) : nil
        request.body.withUnsafeBytes { raw in
            for i in 0..<(w * h) {
                for k in 0..<3 {
                    let v = raw.loadUnaligned(fromByteOffset: (i * c + k) * 2, as: UInt16.self).littleEndian
                    pixels[i * 3 + k] = Float(v) / 65535
                }
                if c == 4 { alpha![i] = raw.loadUnaligned(fromByteOffset: (i * c + 3) * 2, as: UInt16.self).littleEndian }
            }
        }
        let initial = try params(["film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura", "grain_active": false])
        let config = String(data: jsonData(initial), encoding: .utf8)!
        var reply: UnsafeMutablePointer<CChar>?
        let session = pixels.withUnsafeBufferPointer { p -> OpaquePointer? in
            var image = spk_image(data: p.baseAddress, width: UInt32(w), height: UInt32(h), channels: 3)
            return spk_open(handle, &image, config, &reply)
        }
        if let reply { spk_string_free(reply) }
        guard let session else { throw fail(String(cString: spk_last_error(handle))) }
        let frame = Frame(session: session, width: w, height: h, alpha: alpha)
        frame.sent = initial
        if isPreview { preview = frame } else { full = frame }
        return jsonData(["sourceId": frame.id, "width": w, "height": h])
    }
    func render(_ request: Request) throws -> Response {
        let input = try object(request.body)
        guard let id = input["sourceId"] as? String,
              let frame = [preview, full].compactMap({ $0 }).first(where: { $0.id == id }),
              let requested = input["params"] as? [String: Any] else { throw fail("Source expired; read the Photoshop image again") }
        let isPreview = frame === preview
        // Full residency is released on success OR failure after each apply.
        defer { if !isPreview { full = nil } }
        let wanted = try params(requested, linear: frame.linear)
        let edge = wanted["overscan_active"] as? Bool == true
        if edge, let alpha = frame.alpha, alpha.contains(where: { $0 != 65535 }) {
            throw fail("片边暂不支持透明像素；请先在 PS 给图像添加不透明背景，再重新读取。")
        }
        let changed = wanted.filter { key, value in
            guard let old = frame.sent[key] as? NSObject, let new = value as? NSObject else { return true }
            return !old.isEqual(new)
        }
        if !changed.isEmpty {
            let delta = String(data: jsonData(changed), encoding: .utf8)!
            var reply: UnsafeMutablePointer<CChar>?
            let setStatus = spk_set_params(frame.session, delta, &reply)
            if let reply { spk_string_free(reply) }
            try checked(setStatus)
            frame.sent = wanted
        }
        var result = spk_result()
        let started = Date()
        try checked(spk_reprint(frame.session, "full", &result))
        defer { spk_result_free(&result) }
        let w = Int(result.width), h = Int(result.height)
        guard let pixels = result.rgba16, w > 0, h > 0, w * h <= 100_000_000,
              Int(result.row_stride_px) >= w,
              edge || (w == frame.width && h == frame.height) else { throw fail("Unexpected output geometry") }
        var packed = Data(count: w * h * 8)
        packed.withUnsafeMutableBytes { raw in
            let target = raw.bindMemory(to: UInt16.self)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x, j = y * Int(result.row_stride_px) + x
                    for c in 0..<3 { target[i * 4 + c] = pixels[j * 4 + c].littleEndian }
                    target[i * 4 + 3] = (edge ? 65535 : (frame.alpha?[i] ?? 65535)).littleEndian
                }
            }
        }
        let ms = Date().timeIntervalSince(started) * 1000
        let headers = ["X-Width": "\(w)", "X-Height": "\(h)", "X-Render-Ms": String(format: "%.1f", ms), "X-Negative-Cached": "\(result.negative_was_cached)"]
        if isPreview {
            return Response(body: try png(packed, width: w, height: h), type: "image/png", headers: headers)
        }
        return Response(body: packed, type: "application/octet-stream", headers: headers)
    }
    func png(_ data: Data, width: Int, height: Int) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.rommrgb),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                bytesPerRow: width * 8, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder16Little),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw fail("Preview color conversion failed") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let converted = ctx.makeImage() else { throw fail("Preview image failed") }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw fail("PNG writer unavailable") }
        CGImageDestinationAddImage(dest, converted, nil)
        guard CGImageDestinationFinalize(dest) else { throw fail("PNG encoding failed") }
        return output as Data
    }
}

struct Request {
    let method: String, path: String
    let query: [String: String], headers: [String: String]
    let body: Data
}
struct Response {
    var status = 200
    let body: Data
    var type = "application/json"
    var headers: [String: String] = [:]
}
let networkQueue = DispatchQueue(label: "filmlab.network")
let engineQueue = DispatchQueue(label: "filmlab.engine", qos: .userInitiated)
let maxBody = 400_000_000

final class Connection {
    let socket: NWConnection
    let token: String
    let engine: FilmEngine
    var buffer = Data(), headerEnd: Int?, expected = 0
    var method = "", path = "", headers: [String: String] = [:], query: [String: String] = [:]
    init(_ socket: NWConnection, token: String, engine: FilmEngine) { self.socket = socket; self.token = token; self.engine = engine }
    func start() { socket.start(queue: networkQueue); receive() }
    func receive() {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [self] data, _, done, error in
            if let data { buffer.append(data) }
            do {
                if headerEnd == nil {
                    if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                        guard range.lowerBound < 16384,
                              let text = String(data: buffer[..<range.lowerBound], encoding: .utf8) else { throw fail("Invalid header") }
                        let lines = text.components(separatedBy: "\r\n")
                        let first = lines[0].split(separator: " ")
                        guard first.count == 3, let url = URLComponents(string: "http://127.0.0.1" + first[1]) else { throw fail("Invalid request") }
                        method = String(first[0]); path = url.path
                        for item in url.queryItems ?? [] { query[item.name] = item.value }
                        for line in lines.dropFirst() {
                            guard let colon = line.firstIndex(of: ":") else { throw fail("Invalid header") }
                            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        }
                        guard headers["authorization"] == "Bearer " + token else {
                            send(Response(status: 401, body: jsonData(["error": "Unauthorized"]))); return
                        }
                        guard headers["transfer-encoding"] == nil else { throw fail("Use Content-Length") }
                        expected = Int(headers["content-length"] ?? "0") ?? -1
                        guard expected >= 0, expected <= maxBody else { throw fail("Request too large") }
                        headerEnd = range.upperBound
                    } else if buffer.count > 16384 { throw fail("Header too large") }
                }
                if let end = headerEnd, buffer.count >= end + expected {
                    let request = Request(method: method, path: path, query: query, headers: headers, body: buffer.subdata(in: end..<(end + expected)))
                    buffer = Data()
                    engineQueue.async { [self] in autoreleasepool {
                        let response: Response
                        do {
                            switch (request.method, request.path) {
                            case ("GET", "/health"):
                                response = Response(body: jsonData(["ok": true, "version": "0.3.1", "engine": "native-metal", "catalog": engine.catalog]))
                            case ("POST", "/source"):
                                response = Response(body: try engine.source(request))
                            case ("POST", "/render"):
                                response = try engine.render(request)
                            case ("POST", "/raw/open"):
                                response = Response(body: try engine.openRAW(request))
                            case ("POST", "/raw/render"):
                                response = try engine.renderRAW(request)
                            case ("POST", "/raw/latitude"):
                                response = Response(body: try engine.latitude(request))
                            case ("POST", "/release"):
                                engine.preview = nil; engine.full = nil; engine.raw = nil
                                response = Response(body: jsonData(["ok": true]))
                            default: response = Response(status: 404, body: jsonData(["error": "Unknown route"]))
                            }
                        } catch { response = Response(status: 400, body: jsonData(["error": (error as? Failure)?.message ?? error.localizedDescription])) }
                        send(response)
                    } }; return
                }
                if done || error != nil { socket.cancel() } else { receive() }
            } catch { send(Response(status: 400, body: jsonData(["error": (error as? Failure)?.message ?? "Invalid request"]))) }
        }
    }
    func send(_ response: Response) {
        var header = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\nContent-Type: \(response.type)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for (key, value) in response.headers { header += "\(key): \(value)\r\n" }
        header += "\r\n"
        socket.send(content: Data(header.utf8), completion: .contentProcessed { [self] error in
            if error != nil { socket.cancel(); return }
            socket.send(content: response.body, completion: .contentProcessed { [self] _ in socket.cancel() })
        })
    }
}

do {
    guard CommandLine.arguments.count == 3 else { throw fail("Usage: FilmLabHelper RESOURCES CONFIG_JSON") }
    let config = try object(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    guard let token = config["token"] as? String, token.count >= 32 else { throw fail("Missing local access token") }
    let engine = try FilmEngine(resources: CommandLine.arguments[1])
    let portValue = (config["port"] as? UInt16) ?? 49321
    guard portValue >= 1024, let port = NWEndpoint.Port(rawValue: portValue) else { throw fail("Invalid port") }
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { Connection($0, token: token, engine: engine).start() }
    listener.stateUpdateHandler = { state in
        if case .ready = state { print("FilmLab 0.3.1 ready at 127.0.0.1:\(portValue) — native Metal, local only"); fflush(stdout) }
        if case .failed(let error) = state { fputs("Listener failed: \(error)\n", stderr); exit(1) }
    }
    listener.start(queue: networkQueue)
    dispatchMain()
} catch { fputs("FilmLab: \((error as? Failure)?.message ?? error.localizedDescription)\n", stderr); exit(1) }
