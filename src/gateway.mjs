/**
 * PortHub — 本地模型网关
 *
 * 把各家桌面 App / 订阅账号里的模型，接入支持 OpenAI Chat Completions
 * 协议的本地客户端（Claude Code、cc-switch、以及后续的 Codex 等）。
 *
 * ── 设计要点 ──────────────────────────────────────────────────────────────
 *
 * 1. **多上游（provider）架构**
 *    WorkBuddy 只是第一个 provider。每个 provider 是一个独立模块，只负责：
 *      - 取凭据（含刷新）
 *      - 声明自己的模型目录
 *      - 把一次 chat 请求发出去，拿回 SSE 流
 *    网关主体与 provider 无关，新增 Codex / 豆包 只需加一个文件。
 *
 * 2. **对外只讲 OpenAI 协议**
 *    Anthropic ↔ OpenAI 的转换交给 cc-switch 的本地路由（它原生支持），
 *    网关不重复实现。这样网关保持薄，职责单一。
 *
 * 3. **凭据只读**
 *    只读上游 App 的凭据文件，绝不写回。刷新后的 token 只落在 PortHub
 *    自己的缓存里，避免与 App 自身刷新竞争、或被 App 检测到文件被改。
 *
 * 4. **请求保真**
 *    尽量按官方客户端真实形态构造请求（头、UA、会话 ID、追踪 ID），
 *    减少被识别为自动化流量的概率。具体见 providers/workbuddy.mjs。
 *
 * @module porthub/gateway
 */

import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))

// ───────────────────────────────────────────────────────────────────────────
// 配置
// ───────────────────────────────────────────────────────────────────────────

/**
 * 可写数据目录。
 *
 * 发布版的代码在 App bundle 内（只读、且被签名校验），日志与用户配置
 * 不能写在那里。统一放 ~/Library/Application Support/PortHub，
 * 由启动方通过 PORTHUB_DATA 传入；未设置时回退到代码旁的目录（开发模式）。
 */
const DATA_DIR = process.env.PORTHUB_DATA ?? join(HERE, '..')

const CONFIG_PATH = process.env.PORTHUB_CONFIG ?? join(DATA_DIR, 'porthub.config.json')

const DEFAULTS = {
  port: 15801,
  host: '127.0.0.1',
  /**
   * 每个上游 provider 的开关与参数；enabled 决定是否对外暴露模型。
   *
   * 这里的键是**模块名**（对应 `providers/<键>.mjs`），不一定等于最终注册
   * 的上游 id：一个模块可以按产品变体产出多个上游（workbuddy 就是如此，
   * 见 loadProvider）。
   */
  providers: {
    workbuddy: { enabled: true },
  },
}

/**
 * 合并 provider 配置。
 *
 * 深一层合并：`variants` 这类嵌套对象里用户只写了一个变体时，另一个变体
 * 的默认值不能被整体覆盖掉（否则「只配置国内版」会顺手把国际版也改掉）。
 */
function mergeProviderConfig (base, override) {
  const merged = { ...base, ...override }
  if (base?.variants || override?.variants) {
    merged.variants = { ...base?.variants, ...override?.variants }
  }
  return merged
}

async function loadConfig () {
  try {
    const text = await readFile(CONFIG_PATH, 'utf8')
    const parsed = JSON.parse(text)
    const providers = { ...DEFAULTS.providers }
    for (const [id, providerConfig] of Object.entries(parsed.providers ?? {})) {
      providers[id] = mergeProviderConfig(providers[id], providerConfig)
    }
    return { ...DEFAULTS, ...parsed, providers }
  } catch (error) {
    if (error.code === 'ENOENT') return DEFAULTS
    throw new Error(`PortHub 配置无法解析 (${CONFIG_PATH}): ${error.message}`)
  }
}

// ───────────────────────────────────────────────────────────────────────────
// 日志：同时输出到 stdout 与日志文件，便于菜单栏 App 读取
// ───────────────────────────────────────────────────────────────────────────

const LOG_FILE = process.env.PORTHUB_LOG ?? join(DATA_DIR, 'logs', 'porthub.log')

function log (...args) {
  const line = `${new Date().toISOString()} ${args.map(String).join(' ')}`
  console.log(line)
  void import('node:fs').then(({ appendFileSync, mkdirSync }) => {
    try {
      mkdirSync(dirname(LOG_FILE), { recursive: true })
      appendFileSync(LOG_FILE, line + '\n')
    } catch { /* 日志写失败不影响服务 */ }
  })
}

// ───────────────────────────────────────────────────────────────────────────
// Provider 注册表
// ───────────────────────────────────────────────────────────────────────────

/** 已加载的 provider 实例，按 id 索引。 */
const providers = new Map()

/**
 * 加载一个 provider 模块。
 *
 * 每个 provider 导出以下两个工厂之一（导出哪个都行，网关自己认）：
 *   createProviders(config)  返回 provider 数组，用于一个模块对应多个上游
 *   createProvider(config)   返回单个 provider
 *
 * 数组形式是为「同一份代码服务多个产品变体」准备的：WorkBuddy 的国内版和
 * 国际版是两个独立账号、独立端点，必须注册成两个上游，模型 ID 才不会
 * 互相覆盖。模块名（`workbuddy`）只用来定位文件，注册 id 一律以 provider
 * 自己声明的 `id` 为准。
 *
 * 每个 provider 实例提供：
 *   id            唯一标识（同时是模型 ID 前缀）
 *   displayName   展示名
 *   listModels()  返回模型数组
 *   chat(body, ctx) 返回上游 Response（SSE）
 *   health()      返回 { ok, detail }
 */
async function loadProvider (moduleId, config) {
  const modulePath = join(HERE, 'providers', `${moduleId}.mjs`)
  let module
  try {
    module = await import(modulePath)
  } catch (error) {
    log(`provider "${moduleId}" 加载失败: ${error.message}`)
    return []
  }
  try {
    const created = typeof module.createProviders === 'function'
      ? await module.createProviders(config)
      : [await module.createProvider(config)]
    const instances = []
    for (const instance of created) {
      if (!instance?.id) {
        log(`provider "${moduleId}" 返回了没有 id 的实例，跳过`)
        continue
      }
      if (providers.has(instance.id)) {
        log(`provider "${moduleId}" 的 id "${instance.id}" 与已加载的上游重名，跳过`)
        continue
      }
      providers.set(instance.id, instance)
      instances.push(instance)
      log(`provider "${instance.id}" 已加载（${instance.displayName}）`)
    }
    if (instances.length === 0) log(`provider "${moduleId}" 没有产出任何可用上游`)
    return instances
  } catch (error) {
    log(`provider "${moduleId}" 初始化失败: ${error.message}`)
    return []
  }
}

async function loadAllProviders (config) {
  for (const [id, providerConfig] of Object.entries(config.providers)) {
    if (providerConfig?.enabled === false) {
      log(`provider "${id}" 已禁用，跳过`)
      continue
    }
    await loadProvider(id, providerConfig)
  }
}

// ───────────────────────────────────────────────────────────────────────────
// HTTP 服务
// ───────────────────────────────────────────────────────────────────────────

function json (res, status, payload) {
  const text = JSON.stringify(payload)
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(text) })
  res.end(text)
}

function openaiError (res, status, message, code = 'upstream_error') {
  json(res, status, { error: { message, type: code, code } })
}

async function readBody (req) {
  const chunks = []
  for await (const chunk of req) chunks.push(chunk)
  return Buffer.concat(chunks).toString('utf8')
}

/**
 * 模型 ID 采用 `provider/model` 形式对外暴露，避免不同上游的同名模型
 * 冲突（例如两个上游都有 `glm-5.3`）。cc-switch 里直接填这个完整 ID。
 */
function qualifiedId (providerId, modelId) {
  return `${providerId}/${modelId}`
}

function splitQualifiedId (id) {
  const slash = id.indexOf('/')
  if (slash === -1) return { providerId: null, modelId: id }
  return { providerId: id.slice(0, slash), modelId: id.slice(slash + 1) }
}

const server = createServer((req, res) => {
  handle(req, res).catch((error) => {
    log('未捕获错误:', error?.stack ?? error)
    if (!res.headersSent) openaiError(res, 500, String(error?.message ?? error), 'internal_error')
    else res.end()
  })
})

async function handle (req, res) {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? '127.0.0.1'}`)
  const path = url.pathname.replace(/\/+$/u, '') || '/'

  if (req.method === 'GET' && (path === '/healthz' || path === '/health')) {
    const details = {}
    let ok = true
    for (const [id, provider] of providers) {
      try {
        const h = await provider.health()
        details[id] = h
        if (!h.ok) ok = false
      } catch (error) {
        details[id] = { ok: false, detail: error.message }
        ok = false
      }
    }
    return json(res, ok ? 200 : 503, {
      ok,
      service: 'porthub',
      providers: details,
    })
  }

  if (req.method === 'GET' && path === '/v1/models') {
    const data = []
    for (const [id, provider] of providers) {
      try {
        for (const model of await provider.listModels()) {
          data.push({
            id: qualifiedId(id, model.id),
            object: 'model',
            created: 0,
            owned_by: id,
            ...model.name ? { name: model.name } : {},
            ...model.contextWindow ? { context_window: model.contextWindow } : {},
          })
        }
      } catch (error) {
        log(`provider "${id}" 模型列表失败: ${error.message}`)
      }
    }
    return json(res, 200, { object: 'list', data })
  }

  if (req.method === 'POST' && path === '/v1/chat/completions') {
    return chatCompletions(req, res)
  }

  return openaiError(res, 404, `无此路由: ${req.method} ${path}`, 'not_found')
}

async function chatCompletions (req, res) {
  let incoming
  try {
    incoming = JSON.parse(await readBody(req))
  } catch {
    return openaiError(res, 400, '请求体不是合法 JSON', 'invalid_request')
  }

  const requested = typeof incoming.model === 'string' ? incoming.model : ''
  let { providerId, modelId } = splitQualifiedId(requested)

  // 没写 provider 前缀时：若只有一个 provider 就直接用它；
  // 否则按顺序找第一个认识这个模型的 provider。
  if (providerId === null) {
    if (providers.size === 1) {
      providerId = [...providers.keys()][0]
    } else {
      for (const [id, provider] of providers) {
        try {
          if ((await provider.listModels()).some((m) => m.id === modelId)) { providerId = id; break }
        } catch { /* 该 provider 不可用时继续找 */ }
      }
    }
  }

  const provider = providerId === null ? undefined : providers.get(providerId)
  if (!provider) {
    return openaiError(res, 404, `没有可用的上游能处理模型 "${requested}"`, 'model_not_found')
  }

  const controller = new AbortController()
  req.on('close', () => controller.abort())

  let upstream
  try {
    upstream = await provider.chat({ ...incoming, model: modelId }, { signal: controller.signal })
  } catch (error) {
    if (controller.signal.aborted) return
    const status = Number.isInteger(error?.status) ? error.status : 502
    return openaiError(res, status, `上游请求失败: ${error.message}`, error?.code ?? 'upstream_error')
  }

  if (!upstream.ok) {
    const text = (await upstream.text()).slice(0, 2000)
    let detail = text
    let code = `http_${upstream.status}`
    try {
      const parsed = JSON.parse(text)
      detail = parsed.displayMsg?.zh ?? parsed.displayMsg?.en ?? parsed.msg ?? parsed.message ?? text
      code = parsed.code ?? code
    } catch { /* 非 JSON，保留原文 */ }
    log(`上游拒绝 provider=${providerId} model=${modelId} HTTP=${upstream.status} code=${code}`)
    const passthrough = [401, 402, 429].includes(upstream.status) ? upstream.status : 502
    return openaiError(res, passthrough, `上游错误: ${detail}`, String(code))
  }

  // 上游已是 OpenAI SSE，直接透传；仅补 [DONE] 以防提前断流。
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  })

  const reader = upstream.body.getReader()
  const decoder = new TextDecoder()
  let sawDone = false
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      const text = decoder.decode(value, { stream: true })
      if (text.includes('[DONE]')) sawDone = true
      if (!res.write(text)) await new Promise((resolve) => res.once('drain', resolve))
    }
  } catch (error) {
    log('流中断:', error.message)
  } finally {
    if (!sawDone && res.writable) res.write('data: [DONE]\n\n')
    res.end()
  }
}

// ───────────────────────────────────────────────────────────────────────────
// 启动
// ───────────────────────────────────────────────────────────────────────────

const config = await loadConfig()
await loadAllProviders(config)

server.listen(config.port, config.host, async () => {
  log(`PortHub 已监听 http://${config.host}:${config.port}`)
  log(`已启用上游: ${[...providers.keys()].join(', ') || '(无)'}`)
  for (const [id, provider] of providers) {
    try {
      const h = await provider.health()
      log(`  ${id}: ${h.ok ? '✓' : '✗'} ${h.detail ?? ''}`)
    } catch (error) {
      log(`  ${id}: ✗ ${error.message}`)
    }
  }
})

// 收到终止信号时干净退出（菜单栏 App 会用到）
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    log(`收到 ${signal}，正在停止…`)
    server.close(() => process.exit(0))
    setTimeout(() => process.exit(0), 3000).unref()
  })
}
