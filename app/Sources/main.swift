//
//  main.swift
//  PortHub
//
//  入口。菜单栏 + 主窗口双形态的常规 App（有 Dock 图标）。
//

import AppKit

// 进程启动即在主线程。用 assumeIsolated 明确告诉编译器这一点，
// 避免把整个入口标成 @MainActor 后又在非隔离上下文里调用它。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    // 不在这里设 activationPolicy：由 Info.plist 的 LSUIElement=false 决定。
    app.run()
}
