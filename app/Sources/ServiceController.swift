//
//  ServiceController.swift
//  PortHub
//
//  负责 PortHub 网关进程的生命周期管理与状态查询。
//
//  设计：菜单栏 App 与网关是**两个进程**。这样网关可以独立重启、
//  崩溃时不影响菜单栏；菜单栏只负责拉起/停止/观察它。
//

import Foundation

/// 网关的运行状态。
enum ServiceState: Equatable {
    case stopped
    case starting
    case running
    case failed(String)

    var label: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "启动中…"
        case .running: return "运行中"
        case .failed(let msg): return "异常：\(msg)"
        }
    }

    /// 状态栏圆点颜色语义。
    var indicator: String {
        switch self {
        case .stopped: return "○"
        case .starting: return "◌"
        case .running: return "●"
        case .failed: return "●"
        }
    }
}

/// 一个上游 provider 的健康信息。
struct ProviderHealth {
    let id: String
    let ok: Bool
    let detail: String
}

/// PortHub 网关控制器。
///
/// 只做三件事：启动进程、停止进程、查询 `/healthz`。
/// 所有业务逻辑都在网关里，客户端保持薄。
final class ServiceController {

    /// PortHub 根目录。默认 `~/PortHub`，可用环境变量覆盖。
    let root: URL

    private var process: Process?
    private var logHandle: FileHandle?

    /// 本 App 未 spawn、但由外部启动的网关 PID。
    ///
    /// 启动时若探测到端口已被占用，说明网关是上次会话残留或用户手动起的。
    /// 这时不能不管它——否则 `isRunning` 只看自己的 `process` 句柄，会报告
    /// 「已停止」，而服务其实在跑（Claude Code 能用、界面却说停了）。
    /// 记住它的 PID，才能如实显示状态、并在「停止」时真正结束它。
    private var externalPid: pid_t?

    /// 状态变化回调，供 UI 立即刷新（进程退出等异步事件）。
    var onStateChange: ((ServiceState) -> Void)?

    /// 最近一次已知状态；菜单栏与主窗口据此渲染。
    private(set) var state: ServiceState = .stopped {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    init() {
        // 代码位置按优先级解析：
        //   1. PORTHUB_HOME 环境变量（开发时指向工作副本）
        //   2. App bundle 内的 Resources/gateway（发布版，自包含）
        //   3. ~/PortHub（兼容早期安装）
        //
        // 发布版走第 2 条：网关代码随 App 一起分发，用户无需任何外部依赖。
        let env = ProcessInfo.processInfo.environment["PORTHUB_HOME"]
        if let env {
            self.root = URL(fileURLWithPath: env)
        } else if let bundled = Bundle.main.resourceURL?.appendingPathComponent("gateway"),
                  FileManager.default.fileExists(atPath: bundled.appendingPathComponent("gateway.mjs").path) {
            self.root = bundled
        } else {
            self.root = URL(fileURLWithPath: NSHomeDirectory() + "/PortHub")
        }

        // 可写数据（日志、配置）不能放 bundle 里 —— 那里只读且会被签名校验。
        // 统一放 ~/Library/Application Support/PortHub。
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PortHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.dataDir = support
    }

    /// 可写数据目录（日志、配置副本）。
    let dataDir: URL

    // MARK: - 路径

    /// 网关入口。发布版在 bundle 内，开发版在工作副本。
    var gatewayScript: URL {
        let bundled = root.appendingPathComponent("gateway.mjs")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return root.appendingPathComponent("src/gateway.mjs")
    }

    /// 用户配置：优先用数据目录里的，没有就用随包分发的默认配置。
    var configFile: URL {
        let user = dataDir.appendingPathComponent("porthub.config.json")
        if FileManager.default.fileExists(atPath: user.path) { return user }
        return root.appendingPathComponent("porthub.config.json")
    }

    /// 日志写到数据目录（bundle 内不可写）。
    var logFile: URL { dataDir.appendingPathComponent("porthub.log") }

    /// 网关监听端口。
    ///
    /// 三处来源按优先级：运行时覆盖值（用户在界面里改的）→ 配置文件 → 默认值。
    /// 每次读取都重新解析配置，这样用户改完配置文件、重启服务就能生效，
    /// 不需要重启整个 App。
    var port: Int {
        if let portOverride { return portOverride }
        guard
            let data = try? Data(contentsOf: configFile),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let port = json["port"] as? Int,
            (1024...65535).contains(port)
        else { return Self.defaultPort }
        return port
    }

    /// 监听地址。与 port 同样的优先级：运行时覆盖 → 配置文件 → 默认值。
    var host: String {
        if let hostOverride { return hostOverride }
        guard
            let data = try? Data(contentsOf: configFile),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let host = json["host"] as? String,
            !host.trimmingCharacters(in: .whitespaces).isEmpty
        else { return "127.0.0.1" }
        return host
    }

    private var hostOverride: String?

    /// 用户在界面里临时指定的端口（不写回配置文件时使用）。
    private var portOverride: Int?

    /// 配置缺失时的兜底端口。
    static let defaultPort = 15801

    /// 修改监听地址与端口并写回用户配置，随后需要重启服务才生效。
    ///
    /// 写回的是**用户配置**（数据目录那份），不是 bundle 里的默认配置——
    /// 后者只读。
    func setListen(host newHost: String, port newPort: Int) throws {
        guard (1024...65535).contains(newPort) else {
            throw NSError(domain: "PortHub", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "端口需在 1024–65535 之间"])
        }
        let trimmedHost = newHost.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty else {
            throw NSError(domain: "PortHub", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "监听地址不能为空"])
        }

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: configFile),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = parsed
        }
        json["host"] = trimmedHost
        json["port"] = newPort

        let user = dataDir.appendingPathComponent("porthub.config.json")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: json,
                                             options: [.prettyPrinted, .sortedKeys])
        try out.write(to: user)

        hostOverride = trimmedHost
        portOverride = newPort
    }

    /// 客户端访问地址。监听 0.0.0.0 时仍以 127.0.0.1 对外。
    var baseURL: URL {
        let reachable = host == "0.0.0.0" ? "127.0.0.1" : host
        return URL(string: "http://\(reachable):\(port)")!
    }

    // MARK: - 进程管理

    /// 启动网关。已在运行时直接返回。
    ///
    /// 顺序很关键：**先探活，再决定是否 spawn**。
    ///
    /// 早期版本先设 `.starting`、spawn、再等进程撞端口失败，结果是
    /// 服务明明在跑，界面却报「异常：进程退出（码 1）」——那个码 1 来自
    /// EADDRINUSE，是「已有实例」的信号，不是故障。现在把探活提到最前，
    /// 端口已被占用时直接认领，根本不产生那次注定失败的 spawn。
    func start() {
        guard process == nil else { return }

        // 已有实例在监听 → 认领它，不 spawn
        if probeHealthSync() {
            externalPid = listeningPid()
            state = .running
            return
        }

        // 端口空着但健康检查失败：可能上一次的进程正在退出，稍等再试一次
        usleep(300_000)
        if probeHealthSync() {
            externalPid = listeningPid()
            state = .running
            return
        }

        state = .starting

        guard FileManager.default.fileExists(atPath: gatewayScript.path) else {
            state = .failed("找不到 \(gatewayScript.path)")
            return
        }

        // 解析 node 的绝对路径。
        //
        // 不能用 `zsh -lc node ...`：nvm 的 PATH 写在 ~/.zshrc 里，而
        // login shell（-l）只读 .zprofile/.zlogin，**不读 .zshrc**。于是
        // 从 Finder/Dock 启动的 App 找不到 node，网关起不来，而同一个
        // App 从终端启动却正常（继承了终端的 PATH）—— 这个差异极难排查。
        // 因此这里主动解析 node 路径，不依赖任何 shell 环境。
        guard let nodePath = resolveNodePath() else {
            state = .failed("找不到 node，请确认已安装 Node.js（试过 PATH、nvm、homebrew、/usr/local）")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: nodePath)
        task.arguments = [gatewayScript.path]
        task.currentDirectoryURL = root

        // 告诉网关把日志/配置写到可写目录。bundle 内是只读的，
        // 不传这个变量的话，发布版会因写入失败而丢日志。
        var env = ProcessInfo.processInfo.environment
        env["PORTHUB_DATA"] = dataDir.path
        // 首次运行时把随包分发的默认配置拷到数据目录，之后用户改的是那一份
        seedUserConfigIfNeeded()
        if FileManager.default.fileExists(atPath: configFile.path) {
            env["PORTHUB_CONFIG"] = configFile.path
        }
        task.environment = env

        // 日志追加到文件，便于菜单里「查看日志」。
        try? FileManager.default.createDirectory(
            at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            _ = try? handle.seekToEnd()
            task.standardOutput = handle
            task.standardError = handle
            logHandle = handle
        }

        task.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                try? self.logHandle?.close()
                self.logHandle = nil

                // 主动停止：不报异常
                if case .stopped = self.state { return }

                // 进程退出了，但服务可能仍由别的实例提供（端口被占导致本次
                // spawn 失败就是这种情况）。以健康检查为准，而不是以退出码为准。
                if self.probeHealthSync() {
                    self.externalPid = self.listeningPid()
                    self.state = .running
                    return
                }

                if proc.terminationStatus != 0 {
                    self.state = .failed("进程退出（码 \(proc.terminationStatus)）")
                } else {
                    self.state = .stopped
                }
            }
        }

        do {
            try task.run()
            process = task
            externalPid = nil   // 接管了，不再有外部实例
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// 服务当前由外部进程提供（非本 App 启动）。
    var isExternal: Bool { process == nil && externalPid != nil }

    /// 若服务在应答但本 App 没有它的句柄，认领为外部实例。
    ///
    /// 用于 App 启动时服务已在运行的场景：`start()` 可能没被走到，
    /// 或走到时探测结果与当前不符。由健康检查的成功结果驱动认领，
    /// 保证 `isRunning` 与实际一致。
    func adoptRunningInstanceIfNeeded() {
        guard process == nil else { return }
        if let pid = externalPid, kill(pid, 0) == 0 { return }   // 已认领且仍活着
        externalPid = listeningPid()
    }

    /// 标记服务已确认可用。
    ///
    /// 状态不能只靠「进程已 spawn」判断——进程起来了但端口还没监听时，
    /// 界面会一直停在「启动中」。真正的依据是 /healthz 是否应答，
    /// 所以由 AppModel 在健康检查成功后调用这里推进状态。
    func markRunning() {
        // 用户刚点过「停止」时不要复活。
        //
        // 停止是异步的：SIGTERM 发出后进程可能还活着几百毫秒，期间
        // /healthz 仍会成功应答。若无条件把状态改成 .running，界面就会
        // 在用户点了停止之后弹回「运行中」——这正是「点停止不管用」的
        // 观感来源。
        //
        // 用 stopping 标记抑制这段时间内的状态回滚；stop() 完成后清除。
        if stopping { return }
        state = .running
    }

    /// 停止流程进行中。用于抑制健康检查在此期间把状态改回运行中。
    private var stopping = false

    /// 标记启动失败（进程在但健康检查一直不通）。
    func markFailed(_ reason: String) {
        state = .failed(reason)
    }

    /// 停止网关。
    ///
    /// 要处理两种情况：自己 spawn 的进程（有 Process 句柄），以及
    /// 启动时探测到、直接复用的外部进程（没有句柄，只能按端口找 PID）。
    /// 停止网关。
    ///
    /// 三条路径，按可靠性排序：
    ///   1. 有 Process 句柄 → terminate 自己 spawn 的进程
    ///   2. 无句柄但记了 externalPid → 按 PID 结束
    ///   3. 两者都没有 → **按端口找**。这是兜底，也是早期版本漏掉的一步：
    ///      当 spawn 撞端口失败、而 terminationHandler 里的探测又没赶上时，
    ///      `process` 和 `externalPid` 会同时为 nil。旧代码在这条路径上
    ///      直接 return，界面显示「已停止」而网关仍在跑 —— 也就是
    ///      「点停止不管用」。
    func stop() {
        stopping = true
        defer { stopping = false }
        state = .stopped

        // 路径 1：自己 spawn 的进程
        if let task = process, task.isRunning {
            task.terminate()
            let deadline = Date().addingTimeInterval(3)
            while task.isRunning && Date() < deadline { usleep(100_000) }
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            process = nil
            try? logHandle?.close()
            logHandle = nil
            return
        }
        process = nil
        try? logHandle?.close()
        logHandle = nil

        // 路径 2 + 3：外部实例。优先用记下的 PID，没有就现查端口。
        // 两者都指向同一个目标：谁在监听这个端口，就停谁。
        let target = externalPid ?? listeningPid()
        externalPid = nil
        guard let pid = target else { return }   // 真的没人监听，那就不必做什么

        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0 && Date() < deadline { usleep(100_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }

        // 兜底清理：无论上面走了哪条路径，都再按端口确认一次。
        //
        // 这一步是「关应用时端口必须释放」的保证。之前的实现只在记了
        // externalPid 时才按端口杀，一旦那个值没记上（App 刚启动、
        // 孤儿进程由命令行起、或状态被重置），退出后端口会一直被占着，
        // 下次打开应用就没有管理权。
        forceReleasePort()

        // 复核：端口真的空了吗？没空就如实报告，不要让界面假装已停止。
        // 权限不足或进程僵死都可能让 SIGKILL 也无效，这时用户需要知道真相。
        if listeningPid() != nil {
            state = .failed("停止失败：端口 \(port) 仍被占用")
        }
    }

    /// 启动/停止切换。
    ///
    /// 判断依据是**端口上有没有活着的服务**，而不是本 App 有没有进程句柄。
    /// 早期用 `process == nil` 判断，遇到孤儿进程（比如从命令行启动的）时
    /// 会走向 start()，而 start() 又去「认领」它 —— 结果永远停不掉，
    /// 表现为「打开应用后就没有管理权限了」。
    /// 强制释放端口：找到监听者并结束它，不依赖任何本进程记下的状态。
    ///
    /// 设计意图是「端口归属只有一个管理者」——本 App。因此退出或停止时
    /// 任何占着这个端口的进程都该被清掉，包括：
    ///   - 自己 spawn 的（有句柄）
    ///   - 认领的孤儿进程（有 PID）
    ///   - 完全不知情的第三方实例（只能按端口找）
    ///
    /// 只杀「监听该端口」的进程，不会误伤其它 node 进程。
    private func forceReleasePort() {
        var attempts = 0
        while attempts < 2, let pid = listeningPid() {
            kill(pid, SIGTERM)
            var waited = 0
            while kill(pid, 0) == 0 && waited < 30 {   // 最多等 3 秒
                usleep(100_000); waited += 1
            }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            usleep(200_000)
            attempts += 1
        }
    }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    /// 服务是否在跑。
    ///
    /// 三种来源都算：自己 spawn 的进程、探测到的外部实例、
    /// 以及两者都没有但端口仍在应答（兜底，避免状态与事实不符）。
    var isRunning: Bool {
        if let process, process.isRunning { return true }
        if let pid = externalPid, kill(pid, 0) == 0 { return true }
        // 兜底：端口上真有人在监听就算运行中。
        // 这样即便 externalPid 没记上（App 刚启动、还没轮询到），
        // toggle() 也不会把「打开」理解成「关闭」。
        return listeningPid() != nil
    }

    // MARK: - 状态查询

    /// 同步探测 `/healthz` 是否应答（短超时，仅用于启动前判断）。
    ///
    /// 用信号量把异步请求转成同步：`start()` 需要在决定是否 spawn 之前
    /// 就拿到结果。超时 800ms —— 本机回环足够，且不会拖慢启动。
    func probeHealthSync() -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("healthz"))
        request.timeoutInterval = 0.8

        var alive = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { alive = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 1.2)
        return alive
    }

    /// 查询 `/healthz`，返回上游列表。异步，回调在主线程。
    func fetchHealth(completion: @escaping (Result<[ProviderHealth], Error>) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("healthz"))
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { data, _, error in
            func finish(_ result: Result<[ProviderHealth], Error>) {
                DispatchQueue.main.async { completion(result) }
            }
            if let error { return finish(.failure(error)) }
            guard let data else { return finish(.failure(URLError(.badServerResponse))) }

            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let providers = json["providers"] as? [String: Any]
            else { return finish(.failure(URLError(.cannotParseResponse))) }

            let list: [ProviderHealth] = providers.map { key, value in
                let dict = value as? [String: Any] ?? [:]
                return ProviderHealth(
                    id: key,
                    ok: dict["ok"] as? Bool ?? false,
                    detail: dict["detail"] as? String ?? ""
                )
            }.sorted { $0.id < $1.id }

            finish(.success(list))
        }.resume()
    }

    /// 读日志末尾若干行，供菜单展示。
    func tailLog(lines: Int = 30) -> String {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else {
            return "（暂无日志）"
        }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n")
    }

    // MARK: - 工具

    /// 首次运行时，把随包分发的默认配置复制到可写数据目录。
    ///
    /// 这样用户的修改不会碰到 bundle（只读且会被签名校验），升级 App 时
    /// 也不会覆盖用户的配置。
    private func seedUserConfigIfNeeded() {
        let user = dataDir.appendingPathComponent("porthub.config.json")
        guard !FileManager.default.fileExists(atPath: user.path) else { return }
        let bundled = root.appendingPathComponent("porthub.config.json")
        guard FileManager.default.fileExists(atPath: bundled.path) else { return }
        try? FileManager.default.copyItem(at: bundled, to: user)
    }

    /// 解析 node 可执行文件的绝对路径。
    ///
    /// 按可靠性顺序尝试：当前进程的 PATH → 常见安装位置 → nvm 下最新的版本
    /// → login shell 兜底。App 从 Finder 启动时 PATH 只有系统默认值，
    /// 所以「当前 PATH」通常不含 nvm 的 node，需要靠后面的候选补上。
    private func resolveNodePath() -> String? {
        let fm = FileManager.default

        // 0) App bundle 内自带的 node（发布版走这条，用户无需安装 Node.js）
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("node"),
           fm.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }

        // 1) 当前进程 PATH 里找
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/node"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }

        // 2) 常见固定位置
        for candidate in [
            "/opt/homebrew/bin/node",      // Apple Silicon Homebrew
            "/usr/local/bin/node",          // Intel Homebrew / 官方安装包
            "/usr/bin/node",
        ] where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }

        // 3) nvm：取版本号最大的一个
        let nvmDir = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmDir) {
            let sorted = versions.sorted { a, b in
                a.compare(b, options: .numeric) == .orderedAscending
            }
            for version in sorted.reversed() {
                let candidate = "\(nvmDir)/\(version)/bin/node"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }

        // 4) login shell 兜底（对写了 .zprofile 的安装方式有效）
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        if (try? probe.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            probe.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty, fm.isExecutableFile(atPath: text) { return text }
        }

        return nil
    }

    /// 找出监听本服务端口的进程 PID（用于停止复用的外部实例）。
    private func listeningPid() -> pid_t? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let first = text.split(separator: "\n").first, let pid = pid_t(first) else { return nil }
        return pid
    }

    /// 单引号包裹路径，避免空格/特殊字符被 shell 解释。
    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
