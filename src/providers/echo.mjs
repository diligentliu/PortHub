/**
 * PortHub provider: 本地回显（测试用）
 *
 * 一个不依赖任何外部服务的 provider，用于验证 PortHub 的**多上游聚合**：
 *   - 多个 provider 的模型如何合并到同一个 /v1/models
 *   - 同名模型如何靠 provider 前缀区分
 *   - 请求如何路由到正确的 provider
 *
 * 它模拟一个「第二个平台」，行为完全符合 OpenAI Chat Completions 协议。
 * 生产环境可以在 porthub.config.json 里把它的 enabled 设为 false 关掉。
 *
 * @module porthub/providers/echo
 */

export async function createProvider (config = {}) {
  const prefix = config.replyPrefix ?? '[echo]'

  const MODELS = [
    { id: 'echo-small', name: 'Echo Small', contextWindow: 128_000 },
    { id: 'echo-large', name: 'Echo Large', contextWindow: 256_000 },
    // 故意与 WorkBuddy 的模型同名，用来验证前缀消歧
    { id: 'glm-5.3', name: 'GLM-5.3 (echo)', contextWindow: 1_000_000 },
  ]

  /** 把一次请求渲染成一段文本，作为「模型回复」。 */
  function renderReply (body) {
    const last = [...(body.messages ?? [])].reverse().find((m) => m.role === 'user')
    const text = typeof last?.content === 'string'
      ? last.content
      : Array.isArray(last?.content)
        ? last.content.filter((b) => b?.type === 'text').map((b) => b.text).join(' ')
        : ''
    const toolCount = Array.isArray(body.tools) ? body.tools.length : 0
    return `${prefix} 收到 ${body.messages?.length ?? 0} 条消息、${toolCount} 个工具。你最后说：${text}`
  }

  /** 构造一个符合 OpenAI SSE 格式的流。 */
  function sseStream (text) {
    const encoder = new TextEncoder()
    const id = `echo-${Date.now().toString(36)}`
    const chunks = []

    chunks.push({
      id, object: 'chat.completion.chunk', created: Math.floor(Date.now() / 1000),
      model: 'echo', choices: [{ index: 0, delta: { role: 'assistant', content: '' }, finish_reason: null }],
    })
    // 按字符切片，模拟真实的流式输出
    for (const char of text) {
      chunks.push({
        id, object: 'chat.completion.chunk', created: Math.floor(Date.now() / 1000),
        model: 'echo', choices: [{ index: 0, delta: { content: char }, finish_reason: null }],
      })
    }
    chunks.push({
      id, object: 'chat.completion.chunk', created: Math.floor(Date.now() / 1000),
      model: 'echo', choices: [{ index: 0, delta: {}, finish_reason: 'stop' }],
      usage: { prompt_tokens: 10, completion_tokens: text.length, total_tokens: 10 + text.length },
    })

    const body = chunks.map((c) => `data: ${JSON.stringify(c)}\n\n`).join('') + 'data: [DONE]\n\n'
    return new ReadableStream({
      start (controller) {
        controller.enqueue(encoder.encode(body))
        controller.close()
      },
    })
  }

  return {
    id: 'echo',
    displayName: 'Echo（本地测试）',

    async listModels () {
      return MODELS
    },

    async chat (body) {
      const text = renderReply(body)
      return new Response(sseStream(text), {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      })
    },

    async health () {
      return { ok: true, detail: `本地回显，${MODELS.length} 个模型` }
    },
  }
}
