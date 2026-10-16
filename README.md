# PortHub

把各家桌面 App 里的模型，接入支持 OpenAI 协议的本地客户端（Claude Code、cc-switch 等）。

一个本地网关 + 一个原生 macOS 菜单栏应用。目前支持 **WorkBuddy / WorkBuddy AI**（国内版与国际版），架构上为更多上游预留了位置。

```
Claude Code → cc-switch(15721) → PortHub(15801) → WorkBuddy
```

## 为什么需要它

WorkBuddy 桌面 App 里包含不少模型，但它只服务自己的客户端。PortHub 复用 App 的登录状态，把这些模型以标准 OpenAI 协议暴露在本地端口上，于是任何支持该协议的客户端都能用上。

## 特性

- **自包含**：App 内置 Node.js 运行时与网关代码，下载拖进「应用程序」即可用，无需安装任何依赖
- **多上游架构**：每个上游是一个独立模块，新增只需加一个文件
- **凭据只读**：只读桌面 App 的登录凭据，绝不写回；刷新后的 token 只留在自己的进程内
- **原生菜单栏应用**：Swift + AppKit 编写，静止时 CPU 占用约 0%，内存约 60MB

## 安装

1. 从 [Releases](https://github.com/diligentliu/PortHub/releases) 下载 `PortHub-x.y.z.dmg`
2. 打开 DMG，把 PortHub 拖进「应用程序」
3. 首次打开时右键 → 打开（应用未经 Apple 公证，需手动放行一次）

前置条件：已安装并登录 WorkBuddy 桌面 App。

## 使用

启动 PortHub 后，在 cc-switch 里添加供应商：

| 字段 | 值 |
|---|---|
| Base URL | `http://127.0.0.1:15801` |
| 上游格式 | OpenAI Chat Completions |
| 模型 | `workbuddy/deepseek-v4.1-flash` 等，见 `/v1/models` |

并启用 cc-switch 的本地路由（它负责 Anthropic ↔ OpenAI 的协议转换）。

### 应用行为

| 操作 | 结果 |
|---|---|
| 点窗口的叉 | 从程序坞移除，退到菜单栏常驻，服务继续运行 |
| 菜单栏点退出 / ⌘Q | 应用与服务一起停止 |
| 菜单栏图标 | 纯图标，不带文字 |

## 开发

```bash
# 构建
cd app && ./build.sh

# 构建 + 安装到 /Applications
./build.sh install

# 构建 + 安装 + 打包 DMG
./build.sh release

# 只跑网关（不构建 App）
node src/gateway.mjs
```

### 项目结构

```
PortHub/
├── src/
│   ├── gateway.mjs              # 网关主体，与上游无关
│   └── providers/
│       ├── workbuddy.mjs        # WorkBuddy 上游
│       └── echo.mjs             # 本地回显，用于测试多上游
├── app/
│   ├── Sources/                 # Swift 源码
│   ├── icons/                   # 图标资源
│   └── build.sh                 # 构建脚本
└── porthub.config.json          # 配置
```

### 新增一个上游

在 `src/providers/` 下加一个 `.mjs`，导出 `createProvider(config)`，返回：

```js
{
  id,            // 唯一标识，会作为模型 ID 的前缀
  displayName,   // 展示名
  listModels(),  // 返回 [{ id, name, contextWindow }]
  chat(body, { signal }),  // 返回上游的 SSE Response
  health(),      // 返回 { ok, detail }
}
```

然后在 `porthub.config.json` 里启用。

## 配置

`porthub.config.json`：

```json
{
  "port": 15801,
  "host": "127.0.0.1",
  "providers": {
    "workbuddy": { "enabled": true }
  }
}
```

用户配置在首次运行时复制到 `~/Library/Application Support/PortHub/`，之后的修改以那一份为准（升级 App 不会覆盖）。

## 卸载

1. 退出 PortHub（菜单栏 → 退出）
2. 把「应用程序」里的 PortHub 拖到废纸篓
3. 删除数据目录：`rm -rf ~/Library/Application\ Support/PortHub`

## 说明

本项目的凭据处理是**只读**的：只读取 WorkBuddy 桌面 App 的登录状态，不会修改它。刷新后的 token 只存在于 PortHub 自己的进程内存中。

请遵守你所使用服务的条款。

## License

MIT
