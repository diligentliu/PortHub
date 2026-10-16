/**
 * PortHub provider: WorkBuddy（国内版） / WorkBuddy AI（国际版）
 *
 * 复用 WorkBuddy 桌面 App 的登录凭据，把它的模型接入 PortHub。
 *
 * 两个产品是同一套客户端框架的两个区域变体：各自安装、各自登录，但凭据
 * 写在**同一个** `CodeBuddyExtension` 目录下，只靠文件名区分。所以「哪个
 * 变体可用」由凭据文件是否存在决定，而不是由配置指定 —— 装了哪个、登录了
 * 哪个就接入哪个；两个都登录就同时接入两个独立上游（模型前缀分别是
 * `workbuddy/` 与 `workbuddy-ai/`）。
 *
 * ── 账号安全设计 ──────────────────────────────────────────────────────────
 *
 * WorkBuddy 官方客户端把 `/v2/chat/completions` 标记为
 * `replayClass: "forbidden"`（禁止重放）、`commitPoint: "first-valid-token"`，
 * 并对「第三方接入」有主动检测。因此本 provider 的每一处构造都以
 * 官方客户端的真实行为为准（从 app.asar 与 bundled CLI 中提取）：
 *
 *   1. 请求头分三段：身份段 / 会话段 / 追踪段，逐项对齐官方。
 *   2. 每次请求生成全新的会话 ID 与 trace ID —— 复用同一组 ID 连续发请求
 *      正是「重放」的特征，必须避免。
 *   3. 剥离渠道指纹：system 内容里出现字面量 `x-anthropic-billing-header`
 *      会被上游以 `code 11128` 拒绝（实测确认，大小写敏感）。
 *   4. 凭据只读，绝不写回 App 的文件。
 *   5. 凭据的区域必须与本变体一致 —— 两个 App 共用一个凭据目录，指错文件
 *      等于把一个区域的 token 发到另一个区域的端点（见 assertSameRegion）。
 *
 * 以上每一条都对两个变体同时生效：安全逻辑写在工厂里，不按变体分叉。
 *
 * @module porthub/providers/workbuddy
 */

import { createHash, createDecipheriv, randomUUID, randomBytes } from 'node:crypto'
import { execFile } from 'node:child_process'
import { readFile, stat } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'

// ───────────────────────────────────────────────────────────────────────────
// 变体定义
// ───────────────────────────────────────────────────────────────────────────

/**
 * 两个 App 共用的凭据目录。
 *
 * 国内版写 `workbuddy-desktop.info`，国际版写 `workbuddy-desktop-ai.info`，
 * 同目录不同名。这是两个产品在磁盘上唯一的区分点，所以探测可用性时只需要
 * 看这里的文件在不在。
 */
const AUTH_DIR = join(
  homedir(), 'Library', 'Application Support', 'CodeBuddyExtension',
  'Data', 'Public', 'auth',
)

/**
 * 一个产品变体的全部差异项。
 *
 * 差异集中在这张表里，工厂函数只读表、不写 `if (是国际版)` 分支：将来加
 * 第三个区域是改数据，不是改逻辑。
 *
 * `billingBase` 目前只被刷新端点的 Origin / Referer 用到（PortHub 还没有
 * 接入计费接口），登记在此是为了后续接入时不必再动结构；国际版两个端点
 * 同源，所以它的 billingBase 与 chatBase 相同。
 *
 * 注意 `chatBase` 同时决定目录端点与刷新端点（都是它的子路径），这与官方
 * 客户端一致：国内版走 `copilot.tencent.com`，国际版走 `www.workbuddy.ai`。
 */
const VARIANTS = [
  {
    /** provider 注册 id，也是模型 ID 前缀（`workbuddy/glm-5.3`）。 */
    id: 'workbuddy',
    displayName: 'WorkBuddy',
    /** 出错信息里用的 App 名，让用户知道该去哪个 App 登录。 */
    appName: 'WorkBuddy',
    /** 该变体的凭据 domain 必须落在这个区域。 */
    region: 'cn',
    appBundle: '/Applications/WorkBuddy.app',
    authFilename: 'workbuddy-desktop.info',
    chatBase: 'https://copilot.tencent.com',
    billingBase: 'https://www.codebuddy.cn',
    /**
     * UA 第二段的产品名。
     *
     * 官方客户端在区域之间只换这一处：
     *   国内版 `WorkBuddy/${v} WorkBuddy/${v} CLI/${cli}`
     *   国际版 `WorkBuddy/${v} WorkBuddy AI/${v} CLI/${cli}`
     * 第一段两个区域都写 `WorkBuddy/${v}`，不要「顺手统一」成 displayName。
     */
    uaProduct: 'WorkBuddy',
  },
  {
    id: 'workbuddy-ai',
    displayName: 'WorkBuddy AI',
    appName: 'WorkBuddy AI',
    region: 'global',
    appBundle: '/Applications/WorkBuddy AI.app',
    authFilename: 'workbuddy-desktop-ai.info',
    chatBase: 'https://www.workbuddy.ai',
    billingBase: 'https://www.workbuddy.ai',
    uaProduct: 'WorkBuddy AI',
  },
]

/**
 * 登录 domain 属于哪个区域。
 *
 * 以 `workbuddy.ai` 结尾是国际版，其余（含空）都算国内版：国内版登录后写
 * 的是 `www.workbuddy.cn`，而空 domain 没有任何区域声明，归到国内版是既定
 * 约定。注意这个函数只回答「属于哪边」，空 domain 该不该**拒绝**是另一个
 * 问题，由 assertSameRegion 单独判断。
 */
function regionOf (domain) {
  const lowered = String(domain ?? '').trim().toLowerCase()
  if (lowered === 'workbuddy.ai' || lowered.endsWith('.workbuddy.ai')) return 'global'
  return 'cn'
}

/** 区域的中文名，只用于报错文案。 */
function regionLabel (region) {
  return region === 'global' ? 'WorkBuddy AI（国际版）' : 'WorkBuddy（国内版）'
}

const DEFAULT_SYSTEM = 'You are a helpful assistant.'

/**
 * 国内版目录请求的 User-Agent。
 *
 * 上游按 UA 切分 roster：CLI 形态才返回 `cli` agent（可 chat 的模型集），
 * App 形态返回的是 App 内部 roster（含大量不可 chat 的条目）。
 * 版本号与 chat 无关，仅作形态标识 —— 网关不据此判断模型能力。
 */
const CN_CATALOG_UA = 'CLI/2.63.2 CodeBuddy/2.63.2'

/**
 * cli roster 缺失时的启发式过滤。
 *
 * 目录里明确不可 chat 的条目带有能力标记（如 CodeCompletion），
 * 这些没有 chat 语义。宁可少列几个，也不要把注定失败的模型给用户。
 */
function looksChatCapable (row) {
  const id = String(row.id ?? '')
  if (id === '') return false
  // 这些后缀/前缀的条目是补全、提交信息等非对话能力
  return !/completion|commit|inline|autocomplete|tabnine/i.test(id)
}

/** 凭据快到期前多久开始刷新。 */
const REFRESH_MARGIN_MS = 5 * 60_000

/**
 * 渠道指纹清洗。
 *
 * WorkBuddy 的安全策略会拦截「来自 Anthropic 官方客户端」的请求，返回
 * `code 11128 Illegal API invocation from an unapproved channel`。实测确认
 * 有两个独立的触发源（都在 system 内容里）：
 *
 *   1. `x-anthropic-billing-header: cc_version=…; cc_entrypoint=…;`
 *      Claude Code 每次请求都把它作为 system 的第一段发出，用于 Anthropic
 *      侧的计费归属。
 *
 *   2. `You are Claude Code, Anthropic's official CLI for Claude.`
 *      Claude Code 的身份声明句。**触发词是 `Anthropic's`（带撇号的所有格）**
 *      —— 实测把 `Anthropic's` 换成 `the` 即可通过，而单独出现
 *      "Anthropic"、"official CLI" 等片段都不会触发，说明上游匹配的是这个
 *      特定组合。
 *
 * 处理方式按触发源区分：
 *   - 计费头：整行删除。它是纯标记，删掉不留语义空洞。
 *   - 身份句：只改写 `Anthropic's` 这个所有格，保留句子结构与含义。
 *     不整句删除，因为它是有效的身份说明，删掉会让模型失去上下文。
 *
 * 两个变体共用同一套清洗 —— 拦截策略是产品级的，不分区域。
 */
const CHANNEL_FINGERPRINT = /^[ \t]*x-anthropic-billing-header[ \t]*:.*$/gimu

/** Anthropic 官方客户端的身份声明特征。只改所有格，保留句子其余部分。 */
const ANTHROPIC_POSSESSIVE = /\bAnthropic's\b/giu

function stripChannelFingerprint (text) {
  if (typeof text !== 'string') return text
  return text
    .replace(CHANNEL_FINGERPRINT, '')
    .replace(ANTHROPIC_POSSESSIVE, 'the')
    .trim()
}

// ───────────────────────────────────────────────────────────────────────────
// 凭据：解密 WorkBuddy App 的加密 auth 文件
//
// 格式来自 app.asar 的 sym-v1 实现（WBEV1 字段框架）：
//   key    = sha256(atRestSecretKey 的 utf8 字节)
//   keyId  = sha256(key).hex[:16]
//   AAD    = "WB-AAD\0" | 0x01 | len+("WBEV1") | len+("sym-v1")
//            | uint32(suite) | len+(keyId) | 0x02 | 0x00 | 0x00
//   密文   = AES-256-GCM(key, nonce, aad)，authTag 16 字节
//
// 两个变体的 Electron 用的是同一个私有绑定
// （`electron_browser_workbuddy_storage`），只是二进制不同，所以解密流程
// 完全共用，只有「用哪个 Electron」这一个入参不同。
// ───────────────────────────────────────────────────────────────────────────

function buildAad (keyId, suite) {
  const lenPrefixed = (value) => {
    const bytes = Buffer.from(value, 'utf8')
    const header = Buffer.allocUnsafe(4)
    header.writeUInt32BE(bytes.length)
    return Buffer.concat([header, bytes])
  }
  const suiteBytes = Buffer.allocUnsafe(4)
  suiteBytes.writeUInt32BE(suite)
  return Buffer.concat([
    Buffer.from('WB-AAD\0', 'ascii'),
    Buffer.from([1]),
    lenPrefixed('WBEV1'),
    lenPrefixed('sym-v1'),
    suiteBytes,
    lenPrefixed(keyId),
    Buffer.from([2]),
    Buffer.from([0]),
    Buffer.from([0]),
  ])
}

function openField (key, envelope) {
  const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(envelope.nonce, 'base64'), { authTagLength: 16 })
  decipher.setAAD(buildAad(envelope.keyId, envelope.suite))
  decipher.setAuthTag(Buffer.from(envelope.authTag, 'base64'))
  return Buffer.concat([
    decipher.update(Buffer.from(envelope.ciphertext, 'base64')),
    decipher.final(),
  ]).toString('utf8')
}

// ───────────────────────────────────────────────────────────────────────────
// 变体探测
// ───────────────────────────────────────────────────────────────────────────

/**
 * 解析一个变体实际使用的 App 与凭据路径。
 *
 * 覆盖优先级：`providers.workbuddy.variants.<id>` > 旧顶层键 > 变体默认值。
 *
 * 顶层 `appBundle` / `authFile` 是单变体时代的写法，当时只有国际版，所以
 * 它们继续只作用于 `workbuddy-ai`：老配置原样照旧，不会因为新增国内版而
 * 被套到另一个产品上（那会把国内版的凭据指到国际版的 App 上）。
 */
function resolvePaths (variant, config) {
  const override = config.variants?.[variant.id] ?? {}
  const legacy = variant.region === 'global' ? config : {}
  return {
    appBundle: override.appBundle ?? legacy.appBundle ?? variant.appBundle,
    authFile: override.authFile ?? legacy.authFile ?? join(AUTH_DIR, variant.authFilename),
  }
}

async function fileExists (path) {
  return await stat(path).then(() => true, () => false)
}

/**
 * 读一个凭据文件的明文 domain（只有 token 是加密信封，domain 是明文）。
 *
 * 探测阶段只用它做一次廉价预检，读不到就返回 null —— 探测的职责是「有没有
 * 文件」，一个读不动的文件该由 provider 在真正取凭据时去报错，不该在这里
 * 变成「变体不存在」。
 */
async function peekDomain (authFile) {
  try {
    const raw = JSON.parse(await readFile(authFile, 'utf8'))
    const domain = raw?.auth?.domain
    return typeof domain === 'string' ? domain : ''
  } catch {
    return null
  }
}

/**
 * 探测当前可用的变体。
 *
 * 判据是「凭据文件存在」：装了 App 但没登录视为不可用 —— provider 拿不到
 * token 就没有意义，报「已加载」反而误导；反过来凭据在就说明该 App 至少
 * 登录过。
 *
 * 再加一道区域预检：文件在、但里面是另一个产品的登录时直接跳过并留下原因。
 * 不跳过的话会注册出一个永远 health=false 的上游，用户看到的只是「某个
 * 上游坏了」，而真正的原因是文件指错。预检只做廉价判断，不 spawn Electron。
 *
 * 两个都可用就返回两个，只有一个就返回一个，都没有返回空数组。
 */
async function probeVariants (config) {
  const found = []
  const skipped = []
  for (const variant of VARIANTS) {
    if (config.variants?.[variant.id]?.enabled === false) continue
    const paths = resolvePaths(variant, config)
    if (!await fileExists(paths.authFile)) continue
    const domain = await peekDomain(paths.authFile)
    // domain 为空或读不到都不构成区域声明，放行交给 provider 自己处理。
    if (domain !== null && domain.trim() !== '' && regionOf(domain) !== variant.region) {
      skipped.push(
        `${variant.displayName} 跳过：${paths.authFile} 里是${regionLabel(regionOf(domain))}的登录`
        + `（domain=${JSON.stringify(domain)}）`,
      )
      continue
    }
    found.push({ variant, ...paths })
  }
  return { found, skipped }
}

/** 可用的变体列表（含各自的 App 与凭据路径）。 */
export async function detectVariants (config = {}) {
  return (await probeVariants(config)).found
}

// ───────────────────────────────────────────────────────────────────────────
// Provider 工厂
// ───────────────────────────────────────────────────────────────────────────

/**
 * 为每个可用的变体各建一个 provider。
 *
 * 返回数组而不是单个 provider：网关把每个元素当成一个独立上游，用各自的
 * id 注册，于是两个产品在 `/v1/models` 里分别是 `workbuddy/*` 与
 * `workbuddy-ai/*`，互不覆盖（两个产品的模型 ID 有重叠，例如 `glm-5.3`）。
 *
 * 每个 provider 的凭据缓存、刷新状态、模型目录缓存都是工厂内的闭包，
 * 天然按变体隔离：一个变体刷新 token 不会动到另一个的缓存，也不会把
 * 自己的目录当成对方的答案。
 */
export async function createProviders (config = {}) {
  const { found, skipped } = await probeVariants(config)
  if (found.length === 0) {
    const checked = VARIANTS
      .map((variant) => `${variant.displayName} → ${resolvePaths(variant, config).authFile}`)
      .join('；')
    const reason = skipped.length ? `；${skipped.join('；')}` : ''
    throw new Error(`没有找到任何可用的 WorkBuddy 登录凭据，请先在桌面 App 里登录。已检查：${checked}${reason}`)
  }
  for (const reason of skipped) console.warn(`[workbuddy] ${reason}`)
  return found.map(({ variant, appBundle, authFile }) => createVariantProvider(variant, { appBundle, authFile }))
}

/**
 * 单变体时代的入口，保留给仍按「一个模块一个上游」加载的调用方
 * （例如已打包的 App bundle 里那份旧 gateway.mjs）。
 *
 * 只返回探测到的第一个变体，够用即可 —— 新代码请用 createProviders。
 */
export async function createProvider (config = {}) {
  const [first] = await createProviders(config)
  return first
}

function createVariantProvider (variant, { appBundle, authFile }) {
  const electronBin = join(appBundle, 'Contents', 'MacOS', 'Electron')
  const cliPackage = join(appBundle, 'Contents', 'Resources', 'app.asar.unpacked', 'cli', 'package.json')

  // 端点全部由变体决定，绝不从凭据内容里推导：凭据（含 domain）会随刷新
  // 变化，而「请求该发往哪个产品」是安装事实，不该被一个会变的字段改写。
  const CHAT_URL = `${variant.chatBase}/v2/chat/completions`
  const REFRESH_URL = `${variant.chatBase}/v2/plugin/auth/token/refresh`
  const CONFIG_URL = `${variant.chatBase}/v3/config`

  // ── 密钥与凭据缓存 ──────────────────────────────────────────────────────

  let cachedKey = null
  let credential = null
  let credentialMtime = 0
  let credentialRefreshed = false

  /** 向本变体的 WorkBuddy Electron 要 atRestSecretKey（只读，不落盘）。 */
  function readAtRestSecret () {
    const script = 'process.stdout.write(String(process._linkedBinding("electron_browser_workbuddy_storage").loggerGet()))'
    return new Promise((resolve, reject) => {
      execFile(electronBin, ['-e', script], {
        timeout: 15_000,
        maxBuffer: 1 << 20,
        env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
      }, (error, stdout) => {
        if (error) return reject(new Error(`取 ${variant.appName} 密钥失败: ${error.message}`))
        try {
          const payload = JSON.parse(stdout)
          if (typeof payload.atRestSecretKey !== 'string') throw new Error('载荷缺少 atRestSecretKey')
          resolve(payload.atRestSecretKey)
        } catch (e) {
          reject(new Error(`${variant.appName} 密钥载荷无法解析: ${e.message}`))
        }
      })
    })
  }

  async function protectorKey () {
    if (cachedKey) return cachedKey
    const secret = await readAtRestSecret()
    cachedKey = createHash('sha256').update(secret, 'utf8').digest()
    return cachedKey
  }

  /**
   * 凭据必须属于本变体的区域。
   *
   * 两个 App 共用一个凭据目录、只靠文件名区分，所以「文件指错」是很现实的
   * 失误，而把一个区域的 token 发到另一个区域的端点等于把它泄漏给另一个
   * 产品。宁可报错也不发。
   *
   * 只在 domain **非空且明确属于另一个区域**时拒绝：空 domain 不构成任何
   * 区域声明，拒绝它只会把一个本来能用的文件变成硬故障，而它并没有说错
   * 什么。真正的指错文件一定带着对方区域的 domain（实测两个 App 都会写），
   * 所以这一条足以拦住它。
   */
  function assertSameRegion (domain) {
    if (String(domain ?? '').trim() === '') return
    const region = regionOf(domain)
    if (region === variant.region) return
    throw new Error(
      `${variant.displayName} 的凭据文件里是${regionLabel(region)}的登录`
      + `（domain=${JSON.stringify(domain)}，文件 ${authFile}）；`
      + `请确认该文件来自 ${variant.appName} 的登录`,
    )
  }

  async function readCredentialFromApp () {
    const raw = JSON.parse(await readFile(authFile, 'utf8'))
    const auth = raw.auth ?? {}
    const account = raw.account ?? {}
    // domain 是明文（只有 token 是加密信封），所以区域校验放在取密钥之前：
    // 指错文件时立刻失败，不必先 spawn 一次 Electron。
    const domain = typeof auth.domain === 'string' ? auth.domain : ''
    assertSameRegion(domain)
    const key = await protectorKey()
    const unwrap = (field) => {
      const value = auth[field]
      if (typeof value === 'string') return value
      if (value && typeof value === 'object' && typeof value.envelope === 'string') {
        return openField(key, JSON.parse(Buffer.from(value.envelope, 'base64').toString('utf8')))
      }
      return ''
    }
    // domain 不做默认值填充：它是区域判定的唯一依据，填一个默认值等于伪造
    // 证据。缺失时就是空，X-Domain 相应退化成官方的 X-No-Department-Info。
    return {
      accessToken: unwrap('accessToken'),
      refreshToken: unwrap('refreshToken'),
      domain,
      uid: account.uid ?? '',
      enterpriseId: account.enterpriseId || undefined,
      expiresAt: typeof auth.expiresAt === 'number' ? auth.expiresAt : 0,
    }
  }

  async function refreshCredential (cred) {
    const response = await fetch(REFRESH_URL, {
      method: 'POST',
      headers: {
        'X-Refresh-Token': cred.refreshToken,
        'X-Auth-Refresh-Source': 'workbuddy',
        Accept: 'application/json, text/plain, */*',
        'Content-Type': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
        Origin: variant.billingBase,
        Referer: `${variant.billingBase}/`,
        ...cred.enterpriseId ? { 'X-Enterprise-Id': cred.enterpriseId } : {},
      },
      signal: AbortSignal.timeout(20_000),
    })
    const body = await response.json().catch(() => ({}))
    if (!response.ok || body.code !== 0) throw new Error(`HTTP ${response.status} code=${body.code}`)
    const data = body.data ?? {}
    if (typeof data.accessToken !== 'string' || data.accessToken === '') {
      throw new Error('刷新响应中没有 accessToken')
    }
    return {
      accessToken: data.accessToken,
      ...typeof data.refreshToken === 'string' && data.refreshToken ? { refreshToken: data.refreshToken } : {},
      ...typeof data.expiresIn === 'number' && data.expiresIn > 0
        ? { expiresAt: Date.now() + data.expiresIn * 1000 }
        : {},
      // 刻意不采纳响应里的 domain：端点由变体决定、与 domain 无关，而
      // domain 是区域校验的依据 —— 让一个网络响应去改写它，等于给
      // assertSameRegion 开了一条绕过路径。真要换了区域，App 自己会把新
      // domain 写进凭据文件，下次按 mtime 重读即可。
    }
  }

  /**
   * 当前可用凭据。
   *
   * 只在「App 文件变化」或「token 快过期」时才重新解析，避免每次请求都
   * 去 spawn Electron 取密钥。刷新后的 token 只留在本进程内，不写回 App。
   */
  async function currentCredential () {
    const info = await stat(authFile).catch(() => null)
    const nearExpiry = credential !== null && credential.expiresAt - Date.now() < REFRESH_MARGIN_MS
    const stale = credential === null
      || (!credentialRefreshed && info !== null && info.mtimeMs !== credentialMtime)
      || nearExpiry

    if (!stale) return credential

    if (nearExpiry) {
      try {
        const renewed = await refreshCredential(credential)
        credential = { ...credential, ...renewed }
        credentialRefreshed = true
        return credential
      } catch {
        // 刷新失败则回退到读 App 文件；App 可能已经自己刷新过。
      }
    }
    credential = await readCredentialFromApp()
    credentialMtime = info?.mtimeMs ?? 0
    credentialRefreshed = false
    return credential
  }

  // ── 身份：对齐官方客户端 ────────────────────────────────────────────────

  let appVersion = null
  let cliVersion = null

  async function resolveAppVersion () {
    if (appVersion !== null) return appVersion
    try {
      const plist = await readFile(join(appBundle, 'Contents', 'Info.plist'), 'utf8')
      appVersion = /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/u.exec(plist)?.[1] ?? '0.0.0'
    } catch {
      appVersion = '0.0.0'
    }
    return appVersion
  }

  async function resolveCliVersion () {
    if (cliVersion !== null) return cliVersion
    try {
      const pkg = JSON.parse(await readFile(cliPackage, 'utf8'))
      const custom = pkg?.publishConfig?.customPackage?.version
      cliVersion = typeof pkg.version === 'string' && pkg.version !== '0.0.0'
        ? pkg.version
        : (typeof custom === 'string' ? custom : '')
    } catch {
      cliVersion = ''
    }
    return cliVersion
  }

  /**
   * 官方客户端的 User-Agent（三段式，来自 app.asar 的 Jr()）：
   *   `WorkBuddy/${v}` + `${产品名}/${v}` + 有 CLI 版本时再拼 ` CLI/${cli}`
   *
   * 版本号取自本变体自己的 App bundle：两个 App 的版本并不一致（本机实测
   * 国内版 5.8.3 / 国际版 5.7.6），共用一个版本号会让其中一个冒充另一个。
   */
  async function userAgent () {
    const v = await resolveAppVersion()
    const cli = await resolveCliVersion()
    const parts = [`WorkBuddy/${v}`, `${variant.uaProduct}/${v}`]
    if (cli) parts.push(`CLI/${cli}`)
    return parts.join(' ')
  }

  /** 每次请求一组全新的追踪头（官方 Zr() 的等价实现）。 */
  function newTraceHeaders () {
    const traceId = randomBytes(16).toString('hex')
    const spanId = randomBytes(8).toString('hex')
    const parentId = randomBytes(8).toString('hex')
    return {
      traceparent: `00-${traceId}-${spanId}-01`,
      b3: `${traceId}-${spanId}-1-${parentId}`,
      'X-B3-TraceId': traceId,
      'X-B3-ParentSpanId': parentId,
      'X-B3-SpanId': spanId,
      'X-B3-Sampled': '1',
      'X-Trace-ID': traceId,
    }
  }

  /**
   * 构造发往 WorkBuddy 的请求头：身份段 + 会话段 + 追踪段。
   *
   * 空字段走官方的 X-No-* 约定（发 `X-No-User-Id: 1` 而不是省略）。
   * 身份段的 `X-IDE-*` 两个区域都写 `WorkBuddy` —— 官方客户端在区域之间
   * 只换 UA 的产品段，这里跟着它，不自作主张。
   */
  async function buildHeaders (cred) {
    const v = await resolveAppVersion()
    const messageId = randomUUID()
    const conversationId = randomUUID()
    return {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      Authorization: `Bearer ${cred.accessToken}`,
      'x-requested-with': 'XMLHttpRequest',
      'User-Agent': await userAgent(),

      // 身份段
      ...cred.uid ? { 'X-User-Id': cred.uid } : { 'X-No-User-Id': '1' },
      ...cred.enterpriseId
        ? { 'X-Enterprise-Id': cred.enterpriseId, 'X-Tenant-Id': cred.enterpriseId }
        : { 'X-No-Enterprise-Id': '1' },
      ...cred.domain ? { 'X-Domain': cred.domain } : { 'X-No-Department-Info': '1' },
      'X-Product': 'SaaS',
      'X-IDE-Type': 'WorkBuddy',
      'X-IDE-Name': 'WorkBuddy',
      'X-IDE-Version': v,
      'X-Private-Data': 'true',

      // 会话段（每次全新，避免重放特征）
      'X-Conversation-ID': conversationId,
      'X-Conversation-Request-ID': randomUUID(),
      'X-Conversation-Message-ID': messageId,
      'X-Request-ID': messageId,
      'X-Agent-Intent': 'craft',
      'X-Agent-Purpose': 'conversation',
      'x-codebuddy-request': '1',

      // 追踪段
      ...newTraceHeaders(),
    }
  }

  // ── 请求体归一化 ────────────────────────────────────────────────────────

  /**
   * 上游硬性约束（均已在真实端点验证）：
   *   - stream 必须为 true
   *   - 首条消息必须是 system（否则 400 / code 11128）
   *   - tool_choice 只接受字符串
   *   - 不接受 role:"developer"
   *
   * 归一化与变体无关：两个区域跑的是同一套服务端校验，所以这里不分叉，
   * 免得一个变体修好了另一个还漏着。
   */
  function normalizeBody (incoming) {
    const body = { ...incoming }
    body.stream = true
    delete body.stream_options

    // 顶层 system 字段（Anthropic 协议形态）也要清洗。
    // cc-switch 转换后它通常会进 messages，但 PortHub 也可能被直接调用，
    // 两条路径都不能漏。
    if (typeof body.system === 'string') {
      body.system = stripChannelFingerprint(body.system)
    } else if (Array.isArray(body.system)) {
      for (const block of body.system) {
        if (block && block.type === 'text' && typeof block.text === 'string') {
          block.text = stripChannelFingerprint(block.text)
        }
      }
      body.system = body.system.filter(
        (b) => !(b && b.type === 'text' && typeof b.text === 'string' && b.text.trim() === ''),
      )
    }

    if (body.tool_choice !== undefined && typeof body.tool_choice !== 'string') {
      const choice = body.tool_choice
      if (choice && typeof choice === 'object') {
        const type = String(choice.type ?? '').toLowerCase()
        if (type === 'auto' || type === 'required') body.tool_choice = type
        else if (type === 'function') body.tool_choice = choice.function?.name || 'auto'
        else if (type === 'none') { delete body.tool_choice; delete body.tools }
        else delete body.tool_choice
      } else {
        delete body.tool_choice
      }
    } else if (typeof body.tool_choice === 'string' && body.tool_choice.toLowerCase() === 'none') {
      delete body.tool_choice
      delete body.tools
    }

    if (Array.isArray(body.messages)) {
      for (const message of body.messages) {
        if (!message || typeof message !== 'object') continue
        if (message.role === 'developer') message.role = 'system'
        if (typeof message.content === 'string') {
          message.content = stripChannelFingerprint(message.content)
        } else if (Array.isArray(message.content)) {
          for (const block of message.content) {
            if (block && block.type === 'text' && typeof block.text === 'string') {
              block.text = stripChannelFingerprint(block.text)
            }
          }
          message.content = message.content.filter(
            (b) => !(b && b.type === 'text' && typeof b.text === 'string' && b.text.trim() === ''),
          )
        }
      }
      // 中间夹带的 system 会被上游拒绝，统一合并前置。
      const systemParts = []
      const rest = []
      for (const message of body.messages) {
        if (message?.role === 'system') {
          const text = typeof message.content === 'string'
            ? message.content
            : Array.isArray(message.content)
              ? message.content.filter((b) => b?.type === 'text').map((b) => b.text).join('\n')
              : ''
          if (text.trim()) systemParts.push(text)
        } else {
          rest.push(message)
        }
      }
      if (systemParts.length === 0) systemParts.push(DEFAULT_SYSTEM)
      body.messages = [{ role: 'system', content: systemParts.join('\n\n') }, ...rest]
    }

    return body
  }

  // ── 模型目录 ────────────────────────────────────────────────────────────

  let modelCache = { at: 0, models: [] }

  /**
   * 企业账号的目录端点要求成对的身份头。
   *
   * 网关按账号身份切分 `/v3/config`：企业账号不带 `X-User-Id` +
   * `X-Enterprise-Id` 会被静默地当成个人账号回答（模型数不同、少几个型号），
   * 而且这对头是全有全无 —— 只带 `X-Enterprise-Id` 直接被拒，只带
   * `X-User-Id` 什么也不选。所以只有两半都在时才发。
   *
   * 只对国内版发：国际版网关是否也有这条切分未经实测，没有证据就不加。
   */
  function catalogIdentityHeaders (cred) {
    if (variant.region !== 'cn') return {}
    if (!cred.uid || !cred.enterpriseId) return {}
    return {
      'X-User-Id': cred.uid,
      'X-Enterprise-Id': cred.enterpriseId,
      'X-Tenant-Id': cred.enterpriseId,
      ...cred.domain ? { 'X-Domain': cred.domain } : {},
    }
  }

  async function fetchModels () {
    if (Date.now() - modelCache.at < 5 * 60_000 && modelCache.models.length) return modelCache.models
    const cred = await currentCredential()
    const response = await fetch(CONFIG_URL, {
      headers: {
        Authorization: `Bearer ${cred.accessToken}`,
        Accept: 'application/json',
        Origin: variant.billingBase,
        Referer: `${variant.billingBase}/`,
        'X-Requested-With': 'XMLHttpRequest',
        'X-Product': 'SaaS',
        ...catalogIdentityHeaders(cred),
        // 目录请求的 UA 与 chat 不同，这是 load-bearing 的：
        //
        // 上游网关按 UA 切分 roster。国内版用 App 形态 UA 时，返回的
        // agents 里**没有 cli**，于是「可 chat 的模型集」无从取得；
        // 必须用 CLI 形态（CLI/x.y.z CodeBuddy/x.y.z）才会出现 cli。
        // 国际版反过来只认 App 形态。
        //
        // 早期版本对两个区域都发 App 形态 UA，靠「cli 缺失 → 不过滤」
        // 侥幸列出了模型。那是个定时炸弹：上游一旦补上 cli，过滤结果
        // 会变成 0 个模型。
        'User-Agent': variant.region === 'cn' ? CN_CATALOG_UA : await userAgent(),
      },
      signal: AbortSignal.timeout(20_000),
    })
    const body = await response.json()
    const data = body.data ?? body
    const rows = Array.isArray(data.models) ? data.models : []
    const cliAgent = Array.isArray(data.agents)
      ? data.agents.find((a) => a.name === 'cli' || a.id === 'cli')
      : null
    const allowed = Array.isArray(cliAgent?.models) ? new Set(cliAgent.models) : null

    // cli roster 缺失时**不能**退化成「不过滤」。
    //
    // 目录文档里混着 CodeCompletion、CommitMessage 这类根本不能 chat 的
    // 内部模型，不过滤会把它们暴露给用户，调用必然失败。这里退回到
    // 「只保留看起来像 chat 模型的条目」，并在日志里说明，而不是静默
    // 把整份文档端出去。
    if (allowed === null) {
      console.warn(`[porthub] provider "${variant.id}" 目录里没有 cli roster，退回启发式过滤`)
    }

    const models = rows
      .filter((row) => row && typeof row.id === 'string')
      .filter((row) => (allowed !== null ? allowed.has(row.id) : looksChatCapable(row)))
      .filter((row) => row.disabled !== true)
      .filter((row) => {
        const win = row.contextWindow ?? row.maxInputTokens
        const size = typeof win === 'object' && win !== null ? win.defaultLength : win
        return typeof size !== 'number' || size > 0
      })
      .map((row) => {
        const win = row.contextWindow ?? row.maxInputTokens
        const contextWindow = typeof win === 'object' && win !== null
          ? (win.supportedLengths?.at(-1) ?? win.defaultLength ?? 0)
          : (win ?? 0)
        return { id: row.id, name: row.name ?? row.id, contextWindow }
      })

    modelCache = { at: Date.now(), models }
    return models
  }

  // ── 对外接口 ────────────────────────────────────────────────────────────

  return {
    id: variant.id,
    displayName: variant.displayName,

    listModels: fetchModels,

    async chat (body, { signal }) {
      const cred = await currentCredential()
      const headers = await buildHeaders(cred)
      const payload = normalizeBody(body)
      return fetch(CHAT_URL, {
        method: 'POST',
        headers,
        body: JSON.stringify(payload),
        signal,
      })
    },

    async health () {
      try {
        const cred = await currentCredential()
        const models = await fetchModels()
        return {
          ok: true,
          detail: `已登录 uid=${cred.uid || '(空)'}，${models.length} 个模型，token 有效至 ${new Date(cred.expiresAt).toISOString()}`,
          models: models.length,
          expiresAt: cred.expiresAt,
        }
      } catch (error) {
        return { ok: false, detail: error.message }
      }
    },
  }
}
