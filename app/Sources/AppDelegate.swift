//
//  AppDelegate.swift
//  PortHub
//
//  应用主体：主窗口 + 状态栏双形态。
//
//  行为约定（用户明确要求）：
//    - 有主窗口，能看状态、模型、日志
//    - 关窗 ≠ 退出：服务继续跑，状态栏图标常驻
//    - 只有菜单栏里的「退出」才真正结束进程
//    - 状态栏图标是 App 图标的缩小版（模板图，跟随系统明暗）
//

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private let controller = ServiceController()
    private var model: AppModel!

    private let launchAtLoginKey = "LaunchAtLogin"

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel(controller: controller)

        setupStatusItem()

        // 首次启动默认开启登录自启
        if UserDefaults.standard.object(forKey: launchAtLoginKey) == nil {
            UserDefaults.standard.set(true, forKey: launchAtLoginKey)
        }

        controller.start()

        // activationPolicy 已由 Info.plist 的 LSUIElement=false 声明，
        // 这里不再运行时切换 —— 重复设置会与 LaunchServices 状态冲突，
        // 导致窗口被创建却不参与屏幕合成（visible=true 但看不见）。
        showWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关掉最后一个窗口时不退出 —— 留在状态栏继续跑
        false
    }

    /// 窗口关闭后：从程序坞移除，只在菜单栏常驻。
    func windowWillClose(_ notification: Notification) {
        // .accessory = 不在 Dock 显示、不出现在 ⌘Tab，只保留状态栏项。
        // 用 async 让窗口先完成关闭动画，避免切换策略时闪一下。
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出 App = 停掉网关。
        //
        // 用户语义（按常规软件直觉）：
        //   - 点窗口的叉          → 退到菜单栏，服务继续跑
        //   - 菜单栏点退出 / 退出 App → 整个工具下班，服务随之停止
        //
        // 早期版本在这里什么都不做，网关变成 launchd 收养的孤儿进程继续
        // 监听端口，于是「退出了 App 但 Claude Code 还能用」—— 这不是用户
        // 要的。这里显式停掉它。
        controller.stop()
    }

    /// 点 Dock 图标时把窗口找回来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        statusItem.button?.toolTip = "PortHub"
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.target = self
        // 左键点击弹菜单（而不是切窗口），符合状态栏工具的习惯
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 状态栏图标：App 图标的缩小版，作为模板图交给系统着色。
    ///
    /// 菜单栏只要一个图标，**不带任何文字**。状态信息一律通过图标本身
    /// 传达（见 updateStatusIcon 的着色逻辑），或点开菜单查看。
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let icon = NSImage(named: "menubar")
            ?? Bundle.main.image(forResource: "menubar")
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: "PortHub")
        icon?.isTemplate = true   // 关键：跟随系统明暗自动反色
        button.image = icon
        button.imagePosition = .imageOnly
        button.title = ""         // 明确清空：只留图标
    }

    @objc private func statusItemClicked() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // 弹完清掉，避免下次左键直接弹旧菜单
        statusItem.menu = nil
    }

    // MARK: - 主窗口

    func showWindow() {
        // 重新出现窗口时回到常规模式，让 Dock 图标和 ⌘Tab 都能找到它
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = MainView(model: model)
        let hosting = NSHostingController(rootView: view)

        // 显式给内容视图一个初始尺寸。只用 contentViewController 时，
        // SwiftUI 的 minWidth/minHeight 会让窗口尺寸与预期不符，
        // 且内容视图可能不被布局（窗口可见但空白）。
        let contentRect = NSRect(x: 0, y: 0, width: 760, height: 620)
        hosting.view.frame = contentRect

        let win = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.contentViewController = hosting
        win.title = "PortHub"
        win.minSize = NSSize(width: 680, height: 480)
        win.isReleasedWhenClosed = false
        win.center()
        win.delegate = self

        // 关键：先 orderFront 让窗口进入窗口服务器，再激活。
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    @objc private func openWindow() {
        showWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 状态栏菜单

extension AppDelegate: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = NSMenuItem(title: "打开 PortHub 窗口", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let status = NSMenuItem(
            title: "状态：\((model?.state ?? controller.state).label)",
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if let providers = model?.providers, !providers.isEmpty {
            for p in providers {
                let item = NSMenuItem(
                    title: "\(p.ok ? "✓" : "✗") \(p.id)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.toolTip = p.detail
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: controller.isRunning ? "停止服务" : "启动服务",
            action: #selector(toggleService), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func toggleService() {
        model.toggleService()
        updateStatusIcon()
    }
}
