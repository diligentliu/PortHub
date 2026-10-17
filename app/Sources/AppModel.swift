//
//  AppModel.swift
//  PortHub
//
//  UI 与服务之间的状态桥梁。SwiftUI 视图观察它，它负责调用
//  ServiceController 并持有最新状态。
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var state: ServiceState = .stopped
    @Published private(set) var providers: [ProviderHealth] = []
    @Published private(set) var models: [(id: String, owner: String)] = []
    @Published private(set) var healthError: String?

    /// 模型页搜索关键字。
    @Published var searchText: String = ""

    /// 监听地址编辑框的临时值。
    @Published var hostDraft: String = ""

    /// 端口编辑框的临时值。
    @Published var portDraft: String = ""

    /// 端口修改的错误提示。
    @Published var portError: String?

    /// 登录时启动（写入 UserDefaults，由 AppDelegate 读取）。
    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "LaunchAtLogin") }
    }

    /// 当前监听地址（供界面显示）。
    var currentHost: String { controller.host }

    /// 当前端口（供界面显示）。
    var currentPort: Int { controller.port }

    /// 输入是否与当前生效值不同。
    var listenChanged: Bool {
        hostDraft != currentHost || portDraft != String(currentPort)
    }

    let controller: ServiceController

    private var timer: Timer?

    init(controller: ServiceController) {
        self.controller = controller
        self.launchAtLogin = UserDefaults.standard.object(forKey: "LaunchAtLogin") as? Bool ?? true

        controller.onStateChange = { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
                self?.refresh()
            }
        }
        self.state = controller.state
        self.hostDraft = controller.host
        self.portDraft = String(controller.port)

        // 每 5 秒刷新一次；窗口关着时也继续（菜单栏要反映状态）
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// 加载当前生效的监听配置到编辑框。
    func loadListenDraft() {
        hostDraft = currentHost
        portDraft = String(currentPort)
    }

    /// 应用监听地址与端口：写配置并重启服务。
    ///
    /// 地址与端口一起改，因为它们共同构成 cc-switch 里的 Base URL；
    /// 分两次改会让某个中间状态不可用。
    func applyListen() {
        let host = hostDraft.trimmingCharacters(in: .whitespaces)
        let portText = portDraft.trimmingCharacters(in: .whitespaces)

        guard !host.isEmpty, host.rangeOfCharacter(from: .whitespaces) == nil else {
            portError = "监听地址不能为空，也不能包含空格"
            return
        }
        guard let newPort = Int(portText), (1024...65535).contains(newPort) else {
            portError = "端口需为 1024–65535 之间的数字"
            return
        }

        do {
            // 先停旧服务（它还在旧地址上），再写配置、按新参数启动
            controller.stop()
            try controller.setListen(host: host, port: newPort)
            portError = nil
            refresh()
            controller.start()
        } catch {
            portError = error.localizedDescription
        }
    }

    func toggleService() {
        controller.toggle()
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            refresh()
        }
    }

    // MARK: - 派生状态

    var isRunning: Bool { controller.isRunning }
    var baseURL: String { controller.baseURL.absoluteString }
    var anyProviderDown: Bool { providers.contains { !$0.ok } }

    /// 日志末尾内容，供日志页展示。
    var logText: String { controller.tailLog(lines: 200) }

    /// 按搜索关键字过滤后的模型。
    var filteredModels: [(id: String, owner: String)] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return models }
        return models.filter { $0.id.lowercased().contains(q) || $0.owner.lowercased().contains(q) }
    }

    /// 过滤后按上游分组的模型，供模型页展示。
    var filteredGroups: [ModelGroup] {
        var byOwner: [String: [String]] = [:]
        for m in filteredModels {
            let short = m.id.contains("/")
                ? String(m.id.split(separator: "/", maxSplits: 1).last ?? "")
                : m.id
            byOwner[m.owner, default: []].append(short)
        }
        return byOwner.keys.sorted().map { ModelGroup(provider: $0, ids: byOwner[$0]!.sorted()) }
    }

    /// 模型按上游分组（不过滤）。
    var groupedModels: [ModelGroup] { filteredGroups }

    func refresh() {
        state = controller.state
        guard controller.isRunning else {
            providers = []
            models = []
            healthError = nil
            return
        }
        controller.fetchHealth { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let list):
                self.providers = list
                self.healthError = nil
                // 健康检查通过 = 服务真的可用了，推进状态。
                // 之前状态只在进程 spawn 时设为 .starting，没有任何地方
                // 改回 .running，导致界面永远停在「启动中」。
                // 服务在应答，但可能不是本 App spawn 的（上次残留 / 手动启动）。
                // 让 controller 认领它，否则界面会误报「已停止」。
                self.controller.adoptRunningInstanceIfNeeded()
                self.controller.markRunning()
                self.state = self.controller.state
                self.fetchModels()
            case .failure(let error):
                self.providers = []
                self.models = []
                self.healthError = error.localizedDescription
            }
        }
    }

    private func fetchModels() {
        var request = URLRequest(url: controller.baseURL.appendingPathComponent("v1/models"))
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let list = json["data"] as? [[String: Any]]
            else { return }
            let parsed = list.compactMap { item -> (String, String)? in
                guard let id = item["id"] as? String else { return nil }
                return (id, item["owned_by"] as? String ?? "?")
            }
            Task { @MainActor in
                self?.models = parsed.map { (id: $0.0, owner: $0.1) }
            }
        }.resume()
    }

    /// 复制 Base URL 到剪贴板（用于填到 cc-switch）。
    func copyBaseURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.baseURL.absoluteString, forType: .string)
    }

    /// 在 Finder 中显示配置文件。
    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([controller.configFile])
    }

}
