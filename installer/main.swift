import Foundation
import Darwin

struct SetupError: Error { let message: String }
let fm = FileManager.default
let pluginName = "SpektraFilmLab PS"
let upia = "/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent"
let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SpektraFilmLab PS", isDirectory: true)
func error(_ text: String) -> SetupError { SetupError(message: text) }
func writeJSON(_ value: Any, _ path: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
}
func readJSON(_ path: URL) throws -> [String: Any] {
    guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else { throw error("配置文件无效。") }
    return result
}
@discardableResult func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
    try p.run(); p.waitUntilExit(); return p.terminationStatus
}
func copy(_ source: URL, _ target: URL) throws {
    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
    try fm.copyItem(at: source, to: target)
}
func prepare(_ package: URL, _ destination: URL, port: Int = 49321) throws {
    for file in ["bin/FilmLabHelper", "bin/libspektrafilm_engine.dylib", "resources/spektrafilm.metallib", "resources/spektrafilm_constants.bin", "plugin/manifest.json"] {
        guard fm.fileExists(atPath: package.appendingPathComponent(file).path) else { throw error("安装包不完整，缺少 \(file)。请重新下载完整 ZIP。") }
    }
    let configURL = destination.appendingPathComponent("config.json")
    let previous = try? readJSON(configURL)
    let oldToken = previous?["token"] as? String
    let token = oldToken.flatMap { $0.count >= 32 ? $0 : nil } ?? UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
    for folder in ["bin", "resources", "plugin", "licenses"] { try copy(package.appendingPathComponent(folder), destination.appendingPathComponent(folder)) }
    for name in ["LICENSE", "NOTICE.md", "安装与使用.md"] { try copy(package.appendingPathComponent(name), destination.appendingPathComponent(name)) }
    let config: [String: Any] = ["token": token, "port": port]
    try writeJSON(config, configURL)
    try writeJSON(config, destination.appendingPathComponent("plugin/config.json"))
    let ccx = destination.appendingPathComponent("SpektraFilmLab-PS.ccx")
    if fm.fileExists(atPath: ccx.path) { try fm.removeItem(at: ccx) }
    guard try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", destination.appendingPathComponent("plugin").path, ccx.path]) == 0 else { throw error("PS 插件生成失败。") }
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ccx.path)
}
// 0 = not listening, 1 = our authenticated engine, 2 = a different service.
func health(_ destination: URL) -> Int {
    guard let config = try? readJSON(destination.appendingPathComponent("config.json")), let token = config["token"] as? String else { return 0 }
    let port = config["port"] as? Int ?? 49321
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 1
    let semaphore = DispatchSemaphore(value: 0)
    var result = 0
    URLSession.shared.dataTask(with: request) { data, response, _ in
        defer { semaphore.signal() }
        if let response = response as? HTTPURLResponse {
            result = 2
            if response.statusCode == 200, let data,
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], body["engine"] as? String == "native-metal" { result = 1 }
        }
    }.resume()
    _ = semaphore.wait(timeout: .now() + 2)
    return result
}
func stop(_ destination: URL) throws {
    guard let saved = try? readJSON(destination.appendingPathComponent("engine.pid.json")), let pid = saved["pid"] as? Int32 else { return }
    // A reused PID must never make the installer terminate another process.
    let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-p", String(pid), "-o", "command="]; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    let command = String(data: data, encoding: .utf8) ?? ""
    let expected = destination.appendingPathComponent("bin/FilmLabHelper").path
    guard command.hasPrefix(expected + " "), health(destination) == 1 else { return }
    kill(pid, SIGTERM)
    for _ in 0..<30 { if health(destination) == 0 { break }; usleep(100000) }
}
func start(_ destination: URL) throws {
    let h = health(destination)
    if h == 1 { print("本机引擎已经运行。回到 Photoshop 打开 SpektraFilmLab PS 即可。"); return }
    if h == 2 { throw error("49321 端口被其他服务或旧版 FilmLab 占用。请关闭旧引擎后再点「启动引擎.command」；安装器不会终止其他服务。") }
    guard fm.fileExists(atPath: destination.appendingPathComponent("config.json").path) else { throw error("请先运行安装.command。") }
    let logURL = destination.appendingPathComponent("engine.log")
    fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let log = try FileHandle(forWritingTo: logURL)
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
    p.arguments = [destination.appendingPathComponent("bin/FilmLabHelper").path, destination.appendingPathComponent("resources").path, destination.appendingPathComponent("config.json").path]
    p.standardInput = FileHandle.nullDevice; p.standardOutput = log; p.standardError = log
    try p.run(); try log.close()
    try writeJSON(["pid": Int(p.processIdentifier)], destination.appendingPathComponent("engine.pid.json"))
    for _ in 0..<40 {
        if health(destination) == 1 { print("本机 Metal 引擎已启动。照片只在本机处理。"); return }
        usleep(250000)
    }
    throw error("引擎未启动。请查看 ~/Library/Application Support/SpektraFilmLab PS/engine.log。")
}

do {
    let args = CommandLine.arguments
    guard args.count >= 2 else { throw error("Usage: FilmLabSetup install PACKAGE | start | stop | prepare PACKAGE DEST [PORT] | start-at DEST | stop-at DEST") }
    switch args[1] {
    case "prepare":
        guard args.count >= 4 else { throw error("prepare needs PACKAGE DEST") }
        let port = args.count > 4 ? Int(args[4]) ?? 0 : 49321
        guard (1024...65535).contains(port) else { throw error("Invalid port") }
        try prepare(URL(fileURLWithPath: args[2]), URL(fileURLWithPath: args[3]), port: port)
        print("已生成此电脑专用的配置与 CCX；其中含本机令牌，请勿转发。")
    case "install":
        guard args.count == 3 else { throw error("安装包路径无效。") }
        guard fm.isExecutableFile(atPath: upia) else { throw error("未找到 Adobe 插件安装器。请先安装并启动 Creative Cloud 和 Photoshop 25 或更新版本。") }
        try stop(support)
        try prepare(URL(fileURLWithPath: args[2]), support)
        guard try run(upia, ["--install", support.appendingPathComponent("SpektraFilmLab-PS.ccx").path]) == 0 else {
            throw error("Adobe 安装器没有完成安装。可双击 ~/Library/Application Support/SpektraFilmLab PS/SpektraFilmLab-PS.ccx 重试。")
        }
        print("PS 插件安装完成。更新已有版本后请重开 Photoshop。")
        try start(support)
        print("使用：Photoshop → 增效工具 → SpektraFilmLab PS → SpektraFilmLab RAW 显影工作台。")
    case "start": try start(support)
    case "stop": try stop(support); print("已停止本安装器启动的引擎。")
    case "start-at", "stop-at":
        guard args.count == 3 else { throw error("需要测试目录。") }
        let destination = URL(fileURLWithPath: args[2])
        if args[1] == "start-at" { try start(destination) } else { try stop(destination) }
    default: throw error("Unknown command")
    }
} catch {
    fputs("SpektraFilmLab PS：\((error as? SetupError)?.message ?? error.localizedDescription)\n", stderr)
    exit(1)
}
