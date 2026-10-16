//
//  Design.swift
//  PortHub
//
//  设计系统：颜色、圆角、间距、卡片样式。
//
//  参照 cc-switch 的视觉语言：
//    - 深色侧栏（图标栏，约 56pt）+ 主内容区
//    - 卡片：圆角 12、比背景略亮的填充、1pt 细边框
//    - 卡片左侧 32pt 圆角图标 + 标题 + 灰色副标题
//    - 状态用彩色圆点 + 徽章
//    - 顶部分段控件为胶囊形
//
//  自适应浅色/深色：所有颜色都由系统语义色派生，不写死。
//

import SwiftUI

enum DS {

    // MARK: - 间距

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: - 圆角

    enum Radius {
        static let card: CGFloat = 12
        static let icon: CGFloat = 8
        static let pill: CGFloat = 999
    }

    // MARK: - 颜色

    enum Palette {
        /// 侧栏底色：比内容区**略深一点点**。
        ///
        /// 不能用 `underPageBackgroundColor` —— 它在浅色模式下是 R0.588 的
        /// 中灰，与内容区（R0.925）对比过强，看起来像两块拼贴的界面。
        /// 系统工具（设置、Finder）的侧栏只比内容区深一档，靠细微色差
        /// 分层，这里照做：浅色下用 R0.90，深色下自动跟随。
        static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.145, green: 0.145, blue: 0.153, alpha: 1)  // 深色：略深于内容区
                : NSColor(srgbRed: 0.902, green: 0.902, blue: 0.910, alpha: 1)  // 浅色：浅灰
        })

        /// 内容区底色：浅色下用近白（而不是 R0.925 的灰），让卡片有依托。
        static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.180, green: 0.180, blue: 0.188, alpha: 1)  // 深色：深灰
                : NSColor(srgbRed: 0.976, green: 0.976, blue: 0.980, alpha: 1)  // 浅色：近白
        })

        /// 卡片填充：浅色下纯白，浮在近白底上靠描边与投影分层。
        static let cardFill = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.235, green: 0.235, blue: 0.243, alpha: 1)  // 深色：比内容区亮一档
                : NSColor.white
        })

        /// 卡片描边：浅色下要够淡，否则一圈圈线会显脏。
        static let cardStroke = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.07)
        })

        /// 选中卡片的填充（绿色微染）
        static let selectedFill = Color.green.opacity(0.10)

        /// 选中卡片描边
        static let selectedStroke = Color.green.opacity(0.45)

        static let ok = Color.green
        static let warn = Color.orange
        static let bad = Color.red
        static let idle = Color.secondary.opacity(0.5)
    }

    // MARK: - 字号

    enum Font {
        static let cardTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let cardSubtitle = SwiftUI.Font.system(size: 11)
        static let sectionTitle = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let mono = SwiftUI.Font.system(size: 11, design: .monospaced)
        static let badge = SwiftUI.Font.system(size: 10, weight: .medium)
    }
}

// MARK: - 卡片容器

/// 统一的卡片外观：圆角 + 填充 + 细边框，可选选中态。
struct Card<Content: View>: View {
    var selected: Bool = false
    var padding: CGFloat = DS.Space.md
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(selected ? DS.Palette.selectedFill : DS.Palette.cardFill)
                    // 极轻的投影：浅色模式下卡片与近白背景的层次主要靠它，
                    // 只靠描边会显得平。深色模式下投影几乎不可见，由填充色差分层。
                    .shadow(color: .black.opacity(0.05), radius: 1.5, y: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(
                        selected ? DS.Palette.selectedStroke : DS.Palette.cardStroke,
                        lineWidth: 1
                    )
            )
    }
}

// MARK: - 状态徽章

/// 小圆点 + 文字的胶囊徽章，用于「运行中」「路由中」这类状态。
struct Badge: View {
    let text: String
    var color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(DS.Font.badge).foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(color.opacity(0.12))
        )
        .overlay(
            Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5)
        )
    }
}

// MARK: - 圆角图标

/// 卡片左侧的圆角方形图标（SF Symbol）。
struct IconTile: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.icon, style: .continuous)
            .fill(tint.opacity(0.15))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(tint)
            )
    }
}

// MARK: - 分区标题

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(DS.Font.sectionTitle)
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(DS.Font.badge)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
