// Native boundary checks: no photos, EXIF or source filenames are written.
import Foundation
import CoreImage
import CoreGraphics
import Metal

func runRAWPipelineTests() throws {
    let engine = try FilmEngine(resources: CommandLine.arguments[1])
    // Independent oracle: ImageDecoder.context and linearProPhoto at the
    // pinned upstream revision 02d82b56cf65f0f8e802a708612edc4e9a4790af.
    let reference = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
        .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false, .highQualityDownsample: true])
    var white: [CGFloat] = [0.9642,1,0.8249], black: [CGFloat] = [0,0,0], gamma: [CGFloat] = [1,1,1]
    var primaries: [CGFloat] = [0.7976749,0.2880402,0, 0.1351917,0.7118741,0, 0.0313534,0.0000857,0.8252100]
    let referenceSpace = CGColorSpace(calibratedRGBWhitePoint:&white,blackPoint:&black,gamma:&gamma,matrix:&primaries)!
    var failures: [String] = []
    func check(_ value: Bool, _ name: String) {
        print("\(value ? "PASS" : "FAIL"): \(name)")
        if !value { failures.append(name) }
    }
    func pixels(_ image: CIImage, context: CIContext, space: CGColorSpace = RAWSource.space) -> [Float] {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var result = [Float](repeating: 0, count: w * h * 4)
        result.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16,
                           bounds: image.extent, format: .RGBAf, colorSpace: space)
        }
        return result
    }
    func delta(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        return zip(a,b).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
    }
    // Alternate fine stripes plus a non-symmetric row ramp: catches poor
    // downsampling, flipped rows, an added transfer curve and HDR clipping.
    let w = 768, h = 512
    var values = [Float](repeating: 1, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        values[i] = x % 2 == 0 ? 0.02 : 3.5
        values[i+1] = Float(y) / Float(h-1)
        values[i+2] = 0.18
    } }
    let data = values.withUnsafeBytes { Data($0) }
    let synthetic = CIImage(bitmapData: data, bytesPerRow: w * 16,
                            size: CGSize(width: w,height: h), format: .RGBAf, colorSpace: referenceSpace)
    let full = pixels(synthetic, context: engine.ci)
    check(delta(full,pixels(synthetic,context:reference,space:referenceSpace)) < 0.00001,
          "destination primaries and D50 white point match independent upstream reference")
    check(full.allSatisfy { $0.isFinite }, "finite float32 boundary")
    check(full.max()! > 3, "highlights above 1 survive Core Image output")
    check(abs(full[2] - 0.18) < 0.002, "18% linear value is not gamma encoded")
    check(abs(full[1] - Float(0)) < 0.002 && abs(full[(h-1)*w*4+1] - 1) < 0.002,
          "bitmap row order preserves source (no vertical flip)")
    let reduced = synthetic.transformed(by: CGAffineTransform(scaleX: 0.137, y: 0.137))
        .cropped(to: CGRect(x:0,y:0,width:105,height:70))
    let previewDelta = delta(pixels(reduced,context:engine.ci),pixels(reduced,context:reference,space:referenceSpace))
    print("preview reference maximum delta: \(previewDelta)")
    check(previewDelta < 0.00001, "preview downsample matches upstream Core Image policy")
    let rawParams = try engine.params([:],linear:true), psParams = try engine.params([:],linear:false)
    check(rawParams["input_cctf_decoding"] as? Bool == false, "RAW input is not decoded twice")
    check(psParams["input_cctf_decoding"] as? Bool == true, "Photoshop rendered RGB is decoded exactly once")
    check(rawParams["input_color_space"] as? String == "ProPhoto RGB" &&
          rawParams["output_color_space"] as? String == "ProPhoto RGB" &&
          rawParams["output_cctf_encoding"] as? Bool == true, "engine color contract is explicit")
    let overrides: [String:Any] = ["input_cctf_decoding":true]
    do { _ = try engine.params(overrides,linear:true); check(false,"caller cannot override RAW gamma contract") }
    catch { check(true,"caller cannot override RAW gamma contract") }

    // Exercise the actual Metal pipeline with the same scene represented
    // either as linear floats or encoded ProPhoto. An incorrect gamma flag
    // must create a measurable difference, not a vacuously passing test.
    func develop(_ values: [Float], linear: Bool) throws -> [UInt16] {
        let p = try engine.params(["film_stock":"kodak_portra_400", "print_stock":"kodak_portra_endura",
                                   "grain_active":false,"halation_active":false,"auto_exposure":false],linear:linear)
        var reply: UnsafeMutablePointer<CChar>?
        let session=values.withUnsafeBufferPointer { buffer -> OpaquePointer? in
            var image=spk_image(data:buffer.baseAddress,width:32,height:24,channels:4)
            return spk_open(engine.handle,&image,String(data:jsonData(p),encoding:.utf8),&reply)
        }
        if let reply { spk_string_free(reply) }
        guard let session else { throw fail("Synthetic engine open failed") }
        defer { spk_session_release(session) }
        var result=spk_result();try engine.checked(spk_reprint(session,"full",&result))
        defer { spk_result_free(&result) }
        guard let data=result.rgba16 else { throw fail("Synthetic engine output missing") }
        return (0..<24).flatMap { y in Array(UnsafeBufferPointer(start:data+y*Int(result.row_stride_px)*4,count:32*4)) }
    }
    var scene=[Float](repeating:1,count:32*24*4)
    for i in 0..<32*24 { scene[i*4]=0.001+Float(i%32)/100;scene[i*4+1]=0.08;scene[i*4+2]=0.18 }
    let encoded=scene.enumerated().map { i,v in i%4==3 ? v : (v < 1/512 ? v*16 : pow(v,1/1.8)) }
    let linearPrint=try develop(scene,linear:true), encodedPrint=try develop(encoded,linear:false)
    let wrongPrint=try develop(scene,linear:false)
    let goodDelta=zip(linearPrint,encodedPrint).map { abs(Int($0)-Int($1)) }.max()!
    let badDelta=zip(linearPrint,wrongPrint).map { abs(Int($0)-Int($1)) }.max()!
    print("Metal equivalent-input delta (UInt16): \(goodDelta); wrong-gamma control: \(badDelta)")
    check(goodDelta<=8 && badDelta>100,"linear RAW and encoded PS inputs converge; double gamma is detectable")

    // Optional real-camera files: local only. No image or metadata export.
    let files=CommandLine.arguments.dropFirst(2).filter { $0 != "--full" && $0 != "--synthetic-only" }
    guard !files.isEmpty || CommandLine.arguments.contains("--synthetic-only") else { throw fail("Supply local RAW fixtures") }
    for (index,path) in files.enumerated() {
        try autoreleasepool {
            let raw = try RAWSource(path:path)
            let settings: [[String:Any]] = [[:], ["temperature":6200,"tint":25], [:], ["lensCorrection":true]]
            var baseline: [Float] = []
            for (step,setting) in settings.enumerated() {
                try raw.configure(setting)
                guard let oracle = CIRAWFilter(imageURL:URL(fileURLWithPath:path)) else { throw fail("Fixture unsupported") }
                oracle.isLensCorrectionEnabled = (setting["lensCorrection"] as? Bool ?? false) && oracle.isLensCorrectionSupported
                oracle.isDraftModeEnabled=false; oracle.boostAmount=0; oracle.boostShadowAmount=0
                oracle.isGamutMappingEnabled=false; oracle.localToneMapAmount=0; oracle.extendedDynamicRangeAmount=0
                if let t = setting["temperature"] as? Float { oracle.neutralTemperature=t }
                if let t = setting["temperature"] as? Int { oracle.neutralTemperature=Float(t) }
                if let n = setting["tint"] as? Int { oracle.neutralTint=Float(n) }
                let actual = try raw.image(raw.linear,small:true)
                var expected = oracle.outputImage!
                expected=expected.transformed(by:CGAffineTransform(translationX:-expected.extent.minX,y:-expected.extent.minY))
                let scale=min(1,1024/max(expected.extent.width,expected.extent.height))
                expected=expected.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                expected=expected.cropped(to:CGRect(x:0,y:0,width:floor(expected.extent.width),height:floor(expected.extent.height)))
                let a=pixels(actual,context:engine.ci), b=pixels(expected,context:reference,space:referenceSpace)
                let d=delta(a,b); print("fixture \(index+1) settings \(step): max delta \(d)")
                check(actual.extent==expected.extent && d < 0.00001,"real RAW matches pinned upstream decode")
                if step==0 { baseline=a }
                if step==1 { check(delta(a,baseline)>0.00001,"custom WB changes linear input") }
                if step==2 { check(a==baseline,"as-shot reset restores original transform") }
                let display=try raw.image(raw.display,small:true)
                check(display.extent==actual.extent,"display and linear geometry agree")
                if step==0 && CommandLine.arguments.contains("--full") {
                    try autoreleasepool {
                        let entire=try raw.image(raw.linear,small:false)
                        var oracleImage=oracle.outputImage!
                        oracleImage=oracleImage.transformed(by:CGAffineTransform(translationX:-oracleImage.extent.minX,y:-oracleImage.extent.minY))
                        oracleImage=oracleImage.cropped(to:CGRect(x:0,y:0,width:floor(oracleImage.extent.width),height:floor(oracleImage.extent.height)))
                        let actualPixels=pixels(entire,context:engine.ci)
                        let expectedPixels=pixels(oracleImage,context:reference,space:referenceSpace)
                        let difference=delta(actualPixels,expectedPixels)
                        print("fixture \(index+1) full resolution max delta: \(difference)")
                        check(entire.extent==oracleImage.extent && difference<0.00001,"full-resolution RAW matches upstream")
                    }
                }
            }
        }
    }
    if files.isEmpty { print("NOT RUN: camera RAW fixture checks (supply local RAW paths)") }
    guard failures.isEmpty else { throw fail(failures.joined(separator:", ")) }
}
