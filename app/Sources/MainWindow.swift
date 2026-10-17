//
//  MainWindow.swift
//  PortHub
//
//  主界面。布局参照 cc-switch：
//    左侧窄图标栏（导航）+ 右侧内容区（卡片列表）
//
//  内容区按页切换：概览 / 上游 / 模型 / 日志
//

import SwiftUI

/// 侧栏导航项。
enum Nav: String, CaseIterable, Identifiable {
    case overview, providers, models, logs
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .providers: return "square.stack.3d.up"
        case .models: return "list.bullet.rectangle"
        case .logs: return "doc.text"
        }
    }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .providers: return "上游"
        case .models: return "模型"
        case .logs: return "日志"
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var nav: Nav = .overview

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(DS.Palette.canvas)
    }

    // MARK: - 左侧图标栏

    private var sidebar: some View {
        VStack(spacing: DS.Space.sm) {
            // 应用标记
            RoundedRectangle(cornerRadius: DS.Radius.icon, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                )
                .padding(.top, DS.Space.md)
                .padding(.bottom, DS.Space.sm)

            ForEach(Nav.allCases) { item in
                Button {
                    nav = item
                } label: {
                    RoundedRectangle(cornerRadius: DS.Radius.icon, style: .continuous)
                        .fill(nav == item ? Color.primary.opacity(0.10) : .clear)
                        .frame(width: 34, height: 30)
                        .overlay(
                            Image(systemName: item.symbol)
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(nav == item ? .primary : .secondary)
                        )
                }
                .buttonStyle(.plain)
                .help(item.title)
            }

            Spacer()

            // 底部状态指示
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .padding(.bottom, DS.Space.md)
                .help(model.state.label)
        }
        .frame(width: 56)
        .background(DS.Palette.sidebar)
    }

    private var statusColor: Color {
        switch model.state {
        case .running: return model.anyProviderDown ? DS.Palette.warn : DS.Palette.ok
        case .starting: return DS.Palette.warn
        case .stopped: return DS.Palette.idle
        case .failed: return DS.Palette.bad
        }
    }

    // MARK: - 内容区

    private var content: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    switch nav {
                    case .overview: overviewPage
                    case .providers: providersPage
                    case .models: modelsPage
                    case .logs: logsPage
                    }
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 顶部工具栏

    private var toolbar: some View {
        HStack(spacing: DS.Space.md) {
            Text(nav.title)
                .font(.system(size: 15, weight: .semibold))

            Spacer()

            // 状态徽章
            Badge(text: model.state.label, color: statusColor)

            // 启停
            Button {
                model.toggleService()
            } label: {
                Label(model.isRunning ? "停止" : "启动",
                      systemImage: model.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 11))
            }
            .controlSize(.small)

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .controlSize(.small)
            .help("刷新")
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
    }

    // MARK: - 概览页

    private var overviewPage: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {

            // 服务卡片
            Card(selected: model.isRunning) {
                HStack(spacing: DS.Space.md) {
                    IconTile(
                        symbol: "point.3.connected.trianglepath.dotted",
                        tint: statusColor,
                        size: 36
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PortHub 网关")
                            .font(DS.Font.cardTitle)
                        Text(model.baseURL)
                            .font(DS.Font.mono)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Badge(text: model.state.label, color: statusColor)
                        if !model.providers.isEmpty {
                            Text("\(model.providers.count) 个上游 · \(model.models.count) 个模型")
                                .font(DS.Font.badge)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            // 快捷入口：全部在应用内跳转，不弹浏览器
            SectionHeader(title: "快捷操作")
            HStack(spacing: DS.Space.md) {
                quickAction("查看模型", "list.bullet.rectangle") {
                    nav = .models
                }
                quickAction("查看上游", "square.stack.3d.up") {
                    nav = .providers
                }
                quickAction("查看日志", "doc.text") {
                    nav = .logs
                }
            }

            // 端口设置
            SectionHeader(title: "端口")
            Card {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    HStack(alignment: .top, spacing: DS.Space.md) {
                        IconTile(symbol: "network", tint: .accentColor, size: 36)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("监听端口").font(DS.Font.cardTitle)
                            Text("客户端通过此端口访问网关")
                                .font(DS.Font.cardSubtitle)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        // 端口输入 + 步进，做成带边框的标准控件
                        HStack(spacing: 0) {
                            TextField("", text: $model.portDraft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .multilineTextAlignment(.center)
                                .frame(width: 62)
                                .onAppear { model.portDraft = String(model.currentPort) }
                                .onSubmit { model.applyPort(model.portDraft) }

                            Divider().frame(height: 18)

                            VStack(spacing: 0) {
                                Button {
                                    model.stepPort(by: 1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 8, weight: .semibold))
                                        .frame(width: 18, height: 10)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    model.stepPort(by: -1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .semibold))
                                        .frame(width: 18, height: 10)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(DS.Palette.cardStroke, lineWidth: 1)
                        )

                        Button("应用") {
                            model.applyPort(model.portDraft)
                        }
                        .controlSize(.regular)
                        .disabled(model.portDraft == String(model.currentPort))
                    }

                    if let err = model.portError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 10))
                            Text(err).font(DS.Font.badge)
                        }
                        .foregroundStyle(DS.Palette.bad)
                    } else if model.portDraft != String(model.currentPort) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10))
                            Text("应用后会重启服务，cc-switch 的 Base URL 需同步改成 \(model.portDraft)")
                                .font(DS.Font.badge)
                        }
                        .foregroundStyle(DS.Palette.warn)
                    } else {
                        Text("改端口会让服务重启约 2 秒；记得同步更新 cc-switch 的 Base URL。")
                            .font(DS.Font.badge)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // 接入方式
            SectionHeader(title: "接入方式")
            Card {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Text("在 cc-switch 中添加供应商，Base URL 填：")
                        .font(DS.Font.cardSubtitle)
                        .foregroundStyle(.secondary)
                    HStack(spacing: DS.Space.sm) {
                        Text(model.baseURL)
                            .font(DS.Font.mono)
                            .textSelection(.enabled)
                        Button {
                            model.copyBaseURL()
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("复制地址")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    Text("上游格式选「OpenAI Chat Completions」，并启用本地路由。")
                        .font(DS.Font.cardSubtitle)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func quickAction(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 16, weight: .regular))
                Text(title).font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.md)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(DS.Palette.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.cardStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 上游页

    private var providersPage: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            SectionHeader(title: "上游", trailing: "\(model.providers.count) 个")

            if let error = model.healthError {
                Card {
                    HStack(spacing: DS.Space.md) {
                        IconTile(symbol: "exclamationmark.triangle.fill", tint: DS.Palette.bad)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("无法连接服务").font(DS.Font.cardTitle)
                            Text(error).font(DS.Font.cardSubtitle).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            } else if model.providers.isEmpty {
                Card {
                    HStack(spacing: DS.Space.md) {
                        IconTile(symbol: "moon.zzz", tint: DS.Palette.idle)
                        Text(model.isRunning ? "正在获取上游状态…" : "服务未运行")
                            .font(DS.Font.cardSubtitle)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else {
                ForEach(model.providers, id: \.id) { p in
                    Card(selected: p.ok) {
                        HStack(alignment: .top, spacing: DS.Space.md) {
                            IconTile(
                                symbol: p.ok ? "checkmark.seal.fill" : "xmark.seal.fill",
                                tint: p.ok ? DS.Palette.ok : DS.Palette.bad,
                                size: 36
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.id).font(DS.Font.cardTitle)
                                Text(p.detail)
                                    .font(DS.Font.cardSubtitle)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Badge(text: p.ok ? "正常" : "异常",
                                  color: p.ok ? DS.Palette.ok : DS.Palette.bad)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 模型页

    private var modelsPage: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            SectionHeader(
                title: "模型",
                trailing: model.searchText.isEmpty
                    ? "共 \(model.models.count) 个"
                    : "匹配 \(model.filteredModels.count) / \(model.models.count)"
            )

            if model.models.isEmpty {
                Card {
                    HStack(spacing: DS.Space.md) {
                        IconTile(symbol: "tray", tint: DS.Palette.idle)
                        Text(model.isRunning ? "正在加载…" : "服务未运行")
                            .font(DS.Font.cardSubtitle).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else {
                // 搜索框：模型多时快速定位
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("搜索模型…", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !model.searchText.isEmpty {
                        Button {
                            model.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.icon, style: .continuous)
                        .fill(DS.Palette.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.icon, style: .continuous)
                        .strokeBorder(DS.Palette.cardStroke, lineWidth: 1)
                )

                // 按上游分组的卡片列表
                ForEach(model.filteredGroups, id: \.provider) { group in
                    Card {
                        VStack(alignment: .leading, spacing: DS.Space.sm) {
                            HStack(spacing: DS.Space.sm) {
                                IconTile(symbol: "square.stack.3d.up.fill",
                                         tint: .accentColor, size: 26)
                                Text(group.provider).font(DS.Font.cardTitle)
                                Spacer()
                                Text("\(group.ids.count) 个")
                                    .font(DS.Font.badge).foregroundStyle(.tertiary)
                            }
                            Divider()
                            // 每个模型一行，等宽字体 + 可复制
                            ForEach(group.ids, id: \.self) { id in
                                ModelRow(qualified: "\(group.provider)/\(id)")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 日志页

    private var logsPage: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            SectionHeader(title: "日志", trailing: "末尾 200 行")
            Card(padding: 0) {
                ScrollView {
                    Text(model.logText.isEmpty ? "（暂无日志）" : model.logText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.md)
                }
                .frame(height: 380)
            }
        }
    }
}

// MARK: - 模型行

/// 单个模型：完整 ID（含上游前缀）+ 一键复制。
/// cc-switch 里要填的就是这个完整 ID，所以复制按钮很有用。
struct ModelRow: View {
    let qualified: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "cube")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 14)

            Text(qualified)
                .font(DS.Font.mono)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(qualified, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(copied ? DS.Palette.ok : .secondary)
            }
            .buttonStyle(.plain)
            .help("复制模型 ID")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }
}

// MARK: - 模型分组

struct ModelGroup {
    let provider: String
    let ids: [String]
}
