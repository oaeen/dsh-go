// SPDX-License-Identifier: MIT
//
// Magpie plugin host manager & local loopback HTTP proxy for DSH.
//
// Spawns Magpie's unmodified `host.js` (with `pi.js` and `bun-shim.mjs`) under
// Node.js 22+, manages `plugins.json`, `plugin-auth.json`, and `plugins/node_modules`,
// serves the Magpie community plugin marketplace (`market.json` + live registry),
// and bridges `dsh-llm-pi-ai` HTTP requests to the plugins' `auth.loader().fetch`.

import { spawn } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import { homedir } from 'node:os'
import path from 'node:path'
import readline from 'node:readline'
import { fileURLToPath } from 'node:url'

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url))
const HOST_JS = path.join(MODULE_DIR, 'host.js')
const PI_JS = path.join(MODULE_DIR, 'pi.js')
const BUN_SHIM = path.join(MODULE_DIR, 'bun-shim.mjs')
const BUILTIN_MARKET_PATH = path.join(MODULE_DIR, 'market.json')

/** Credential env variable name used by Magpie plugin routes in `llm-pi-ai`. */
export const MAGPIE_PLUGIN_KEY_ENV = 'DSH_MAGPIE_PLUGIN_TOKEN'

const MARKET_URLS = [
  'https://cdn.jsdelivr.net/gh/magpie-community/plugins@main/registry.json',
  'https://raw.githubusercontent.com/magpie-community/plugins/main/registry.json',
]

const DIST_BASES = [
  'https://cdn.jsdelivr.net/gh/magpie-community/plugins@dist',
  'https://raw.githubusercontent.com/magpie-community/plugins/dist',
]

const DIST_SCOPE = '@magpie-community/'
const DIST_FILE_RE = /^tgz\/[A-Za-z0-9._-]+\.tgz$/
const PKG_NAME_RE = /^(@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9][a-z0-9._~-]*$/
const GIT_SPEC_RE = /^(?:(?:github|gitlab|bitbucket):|git\+[a-z]+:\/\/|git:\/\/)\S+$|^https?:\/\/(?:www\.)?(?:github\.com|gitlab\.com|bitbucket\.org)\/\S+$|^[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9_.-]+(?:#\S+)?$/
const ROUTE_ID_RE = /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/

/** Per-frame overhead in `host.js` (`FRAME_OVERHEAD = 38`). */
const FRAME_OVERHEAD = 38
const DEFAULT_STREAM_WINDOW = 512 << 10

const NPM_DEFAULT_BASE = {
  '@ai-sdk/anthropic': 'https://api.anthropic.com/v1',
  '@ai-sdk/openai': 'https://api.openai.com/v1',
  '@ai-sdk/google': 'https://generativelanguage.googleapis.com/v1beta',
  '@ai-sdk/github-copilot': 'https://api.githubcopilot.com',
  '@ai-sdk/xai': 'https://api.x.ai/v1',
  '@ai-sdk/mistral': 'https://api.mistral.ai/v1',
  '@ai-sdk/groq': 'https://api.groq.com/openai/v1',
  '@ai-sdk/deepseek': 'https://api.deepseek.com/v1',
}

const KNOWN_THINKING_LEVELS = new Set(['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'])

function readJSON(file, fallback = undefined) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch {
    return fallback
  }
}

function writeAtomicJSON(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 })
  const tmp = `${file}.tmp-${process.pid}-${Date.now()}`
  const text = `${JSON.stringify(data, null, 2)}\n`
  fs.writeFileSync(tmp, text, { mode: 0o600 })
  fs.renameSync(tmp, file)
}

export function isPathSpec(spec) {
  return (
    spec.startsWith('file://') ||
    spec.startsWith('.') ||
    spec.startsWith('/') ||
    spec.startsWith('\\') ||
    path.isAbsolute(spec) ||
    /^[A-Za-z]:[\\/]/.test(spec)
  )
}

export function isGitSpec(spec) {
  return !isPathSpec(spec) && GIT_SPEC_RE.test(spec)
}

export function shortPluginName(pkg) {
  const bare = pkg.includes('/') ? pkg.slice(pkg.indexOf('/') + 1) : pkg
  return bare
    .replace(/^(?:opencode|magpie)-/, '')
    .replace(/-(?:auth|plugin)$/, '')
    .replace(/^middleware-/, '')
}

/** Extracts a device verification code from `authorize.instructions` (matches Magpie's `codeIn`). */
export function extractDeviceCode(instructions) {
  if (typeof instructions !== 'string' || !instructions.trim()) return undefined
  const m =
    instructions.match(/(?:code|码)\s*[:：]\s*([A-Za-z0-9]{3,8}(?:-[A-Za-z0-9]{3,8})+|[A-Z0-9]{6,12})/i) ??
    instructions.match(/\b([A-Z0-9]{4}-[A-Z0-9]{4})\b/)
  return m ? m[1] : undefined
}

/** Sanitizes a provider ID into a valid `llm-pi-ai` route ID (`^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$`). */
export function toPiAiRouteId(providerId) {
  const raw = String(providerId ?? '').trim().toLowerCase()
  if (ROUTE_ID_RE.test(raw)) return raw
  const slug = raw.replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')
  if (!slug) return 'plugin-provider'
  return /^[a-z]/.test(slug) ? slug : `p-${slug}`
}

/** Maps a Magpie provider's AI SDK `npm` identifier to `dsh-llm-pi-ai`'s `api` protocol. */
export function toPiAiProtocol(npm, models = []) {
  const effective = npm || models[0]?.npm || '@ai-sdk/openai-compatible'
  if (effective === '@ai-sdk/anthropic' || effective === '@ai-sdk/google-vertex/anthropic') {
    return 'anthropic-messages'
  }
  if (effective === '@ai-sdk/openai' || effective === '@ai-sdk/azure') {
    return 'openai-responses'
  }
  return 'openai-completions'
}

/** Converts a Magpie provider's model list into `dsh-llm-pi-ai` `models` entries. */
export function toPiAiModels(models = [], modelOverrides = {}) {
  const out = []
  for (const m of models) {
    if (!m || typeof m.id !== 'string' || !m.id.trim() || m.decides) continue
    const id = m.id.trim()
    const override = modelOverrides?.[id]
    const entry = { id }
    const name = override?.name || m.name
    if (typeof name === 'string' && name.trim() && name.trim() !== id) {
      entry.name = name.trim()
    }
    const contextWindow = override?.contextWindow || m.context || m.input || 128000
    if (Number.isInteger(contextWindow) && contextWindow > 0) {
      entry.contextWindow = contextWindow
    }
    const maxTokens = override?.maxTokens || m.output || 16384
    if (Number.isInteger(maxTokens) && maxTokens > 0) {
      entry.maxTokens = maxTokens
    }
    const inputs = Array.isArray(override?.input)
      ? override.input
      : Array.isArray(m.inputs) && m.inputs.length > 0
        ? m.inputs.filter((k) => k === 'text' || k === 'image')
        : m.image
          ? ['text', 'image']
          : ['text']
    if (inputs.length > 0) entry.input = inputs
    const variants = Array.isArray(m.variants) ? m.variants.filter((v) => KNOWN_THINKING_LEVELS.has(v) && v !== 'off') : []
    if (variants.length > 0) {
      const efforts = { off: null }
      for (const v of variants) efforts[v] = v
      entry.reasoningEfforts = efforts
    } else if (m.reasoning) {
      entry.reasoningEfforts = { off: null, low: 'low', medium: 'medium', high: 'high' }
    }
    out.push(entry)
  }
  // `dsh-llm-pi-ai` requires at least one model on a hand-declared route.
  if (out.length === 0) {
    out.push({ id: 'default', name: 'Default', contextWindow: 128000, maxTokens: 16384, input: ['text'] })
  }
  return out
}

function defaultRootDir() {
  const dshHome = process.env.DSH_HOME || path.join(homedir(), '.dsh')
  return path.join(dshHome, 'magpie-plugins')
}

/**
 * Manages the Magpie `host.js` child process, plugin installation, market catalog,
 * and the local loopback HTTP server for `dsh-llm-pi-ai`.
 */
export class MagpieManager {
  #rootDir
  #log
  #onChange
  #fetchFn
  #runInstaller
  #child = null
  #rl = null
  #nextId = 1
  #pending = new Map() // id -> { resolve, reject, stream?, onHead?, onChunk? }
  #initPromise = null
  #loadedPlugins = [] // [{ spec, error, provides }]
  #providersCache = [] // last result of `providers` RPC
  #providersById = new Map()
  #routeToProvider = new Map()
  #marketCache = null
  #marketFetchedAt = 0
  #server = null
  #serverPort = 0
  #disposed = false
  #installQueue = Promise.resolve()

  constructor({
    rootDir = defaultRootDir(),
    log = (line) => console.error(`[dsh-app magpie] ${line}`),
    onChange = () => {},
    fetchFn = globalThis.fetch,
    runInstaller = undefined,
  } = {}) {
    this.#rootDir = rootDir
    this.#log = log
    this.#onChange = onChange
    this.#fetchFn = fetchFn
    this.#runInstaller = runInstaller
    // Ensure the dummy env variable is always present in the DSH engine process
    // so `dsh-llm-pi-ai` considers `apiKeyEnv: MAGPIE_PLUGIN_KEY_ENV` configured.
    if (!process.env[MAGPIE_PLUGIN_KEY_ENV]) {
      process.env[MAGPIE_PLUGIN_KEY_ENV] = 'magpie-plugin-managed'
    }
  }

  get rootDir() {
    return this.#rootDir
  }

  get pluginsDir() {
    return path.join(this.#rootDir, 'plugins')
  }

  get listPath() {
    return path.join(this.#rootDir, 'plugins.json')
  }

  get authPath() {
    return path.join(this.#rootDir, 'plugin-auth.json')
  }

  get optionsPath() {
    return path.join(this.#rootDir, 'plugin-options.json')
  }

  // ── Configuration files ───────────────────────────────────────────────────

  readList() {
    const data = readJSON(this.listPath, { plugins: [] })
    if (!data || typeof data !== 'object' || !Array.isArray(data.plugins)) {
      return { plugins: [] }
    }
    return {
      plugins: data.plugins.filter((p) => p && typeof p.spec === 'string' && p.spec.trim()),
      config: data.config && typeof data.config === 'object' ? data.config : undefined,
      prefer: data.prefer && typeof data.prefer === 'object' ? data.prefer : undefined,
    }
  }

  saveList(list) {
    writeAtomicJSON(this.listPath, list)
  }

  readOptions() {
    const data = readJSON(this.optionsPath, {})
    return data && typeof data === 'object' && !Array.isArray(data) ? data : {}
  }

  saveOptions(options) {
    writeAtomicJSON(this.optionsPath, options)
  }

  packageNameOf(spec) {
    if (isPathSpec(spec)) return spec
    if (isGitSpec(spec)) {
      const pj = readJSON(path.join(this.pluginsDir, 'package.json'), {})
      const deps = pj?.dependencies ?? {}
      for (const [name, s] of Object.entries(deps)) {
        if (s === spec) return name
      }
      return spec
    }
    const at = spec.lastIndexOf('@')
    return at > 0 ? spec.slice(0, at) : spec
  }

  targetOf(spec) {
    if (isPathSpec(spec)) {
      const p = spec.startsWith('file://') ? fileURLToPath(spec) : spec
      return path.resolve(this.#rootDir, p)
    }
    return path.join(this.pluginsDir, 'node_modules', ...this.packageNameOf(spec).split('/'))
  }

  installedVersionOf(spec) {
    try {
      const target = this.targetOf(spec)
      const pkg = readJSON(path.join(target, 'package.json'))
      return typeof pkg?.version === 'string' ? pkg.version : undefined
    } catch {
      return undefined
    }
  }

  // ── Loopback HTTP Server (`127.0.0.1:<port>/magpie/<provider>/v1/...`) ────

  async ensureServer() {
    if (this.#server && this.#serverPort > 0) return this.#serverPort
    const server = http.createServer((req, res) => {
      this.#handleHttpRequest(req, res).catch((err) => {
        this.#log(`loopback error: ${err?.message ?? err}`)
        if (!res.headersSent) {
          res.writeHead(502, { 'content-type': 'application/json' })
        }
        res.end(JSON.stringify({ error: { message: String(err?.message ?? err) } }))
      })
    })
    server.unref()
    await new Promise((resolve, reject) => {
      server.once('error', reject)
      server.listen(0, '127.0.0.1', () => resolve())
    })
    this.#server = server
    this.#serverPort = server.address().port
    return this.#serverPort
  }

  baseUrlFor(providerId, protocol) {
    const route = toPiAiRouteId(providerId)
    // Anthropic protocol in pi-ai appends `/v1/messages` itself; OpenAI protocols keep `/v1`.
    if (protocol === 'anthropic-messages') {
      return `http://127.0.0.1:${this.#serverPort}/magpie/${route}`
    }
    return `http://127.0.0.1:${this.#serverPort}/magpie/${route}/v1`
  }

  async #handleHttpRequest(req, res) {
    const rawUrl = req.url || '/'
    const match = rawUrl.match(/^\/magpie\/([^/?#]+)(\/[^?#]*)?(\?.*)?$/)
    if (!match) {
      res.writeHead(404, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ error: { message: 'Not a Magpie plugin route' } }))
      return
    }
    const routeKey = decodeURIComponent(match[1])
    const restPath = (match[2] || '/') + (match[3] || '')
    const providerId = this.#routeToProvider.get(routeKey) ?? routeKey

    const chunks = []
    for await (const chunk of req) chunks.push(chunk)
    let bodyBuf = chunks.length > 0 ? Buffer.concat(chunks) : undefined

    let modelId = ''
    let parsedBody
    if (bodyBuf && bodyBuf.length > 0) {
      try {
        parsedBody = JSON.parse(bodyBuf.toString('utf8'))
        if (typeof parsedBody?.model === 'string') modelId = parsedBody.model
      } catch {}
    }

    let pp = this.#providersById.get(providerId)
    if (!pp) {
      await this.refreshProviders()
      pp = this.#providersById.get(providerId)
    }
    if (!pp) {
      res.writeHead(404, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ error: { message: `Unknown plugin provider: ${providerId}` } }))
      return
    }

    const m = pp.models?.find((item) => item.id === modelId) ?? { id: modelId, npm: pp.npm, apiId: modelId, url: '' }
    const apiModel = m.apiId || m.id || modelId
    if (parsedBody && apiModel && apiModel !== modelId) {
      parsedBody.model = apiModel
      bodyBuf = Buffer.from(JSON.stringify(parsedBody), 'utf8')
    }

    const loaderOpts = await this.call('load', { provider: pp.id })
    const npm = m.npm || pp.npm || '@ai-sdk/openai-compatible'
    let base = String(loaderOpts?.baseURL || m.url || pp.api || NPM_DEFAULT_BASE[npm] || '').replace(/\/+$/, '')
    if (!base) {
      res.writeHead(502, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ error: { message: `${pp.name} plugin did not specify an upstream baseURL` } }))
      return
    }
    if (
      toPiAiProtocol(npm) === 'anthropic-messages' &&
      loaderOpts?.baseURL &&
      String(m.url || '').replace(/\/+$/, '').endsWith('/v1') &&
      !base.endsWith('/v1')
    ) {
      base += '/v1'
    }

    let targetUrl
    if (restPath.startsWith('/v1/') || restPath === '/v1') {
      targetUrl = base + restPath.slice(3)
    } else {
      targetUrl = base + (restPath.startsWith('/') ? restPath : `/${restPath}`)
    }

    const headers = {}
    for (const [k, v] of Object.entries(req.headers)) {
      if (v === undefined) continue
      const lower = k.toLowerCase()
      if (lower === 'host' || lower === 'connection' || lower === 'content-length') continue
      // Strip DSH's placeholder bearer token so `host.js` sets the plugin's own credential.
      if (lower === 'authorization' && String(v).includes('magpie-plugin-managed')) continue
      if (lower === 'x-api-key' && String(v).includes('magpie-plugin-managed')) continue
      headers[lower] = Array.isArray(v) ? v[0] : String(v)
    }

    const controller = new AbortController()
    req.on('close', () => {
      if (!res.writableEnded) controller.abort()
    })

    await this.fetchStream(
      {
        provider: pp.id,
        model: apiModel,
        npm,
        url: targetUrl,
        method: req.method || 'POST',
        headers,
        body: bodyBuf && bodyBuf.length > 0 ? bodyBuf.toString('base64') : undefined,
      },
      {
        signal: controller.signal,
        onHead: (status, respHeaders) => {
          const outHeaders = {}
          for (const [k, v] of Object.entries(respHeaders ?? {})) {
            const lower = k.toLowerCase()
            if (lower === 'content-encoding' || lower === 'content-length' || lower === 'transfer-encoding') continue
            outHeaders[k] = v
          }
          res.writeHead(status || 200, outHeaders)
        },
        onChunk: async (chunk) => {
          if (res.writableEnded) return
          if (!res.write(chunk)) {
            await new Promise((resolve) => res.once('drain', resolve))
          }
        },
      },
    )
    if (!res.writableEnded) res.end()
  }

  // ── Host Process (`host.js`) ──────────────────────────────────────────────

  hasConfiguredPlugins() {
    return this.readList().plugins.some((p) => !p.off)
  }

  async ensureHost() {
    if (this.#disposed) throw new Error('MagpieManager is disposed')
    if (this.#initPromise) return this.#initPromise
    this.#initPromise = this.#startHost().catch((err) => {
      this.#initPromise = null
      throw err
    })
    return this.#initPromise
  }

  async reloadHost() {
    this.#stopHost()
    if (!this.hasConfiguredPlugins()) {
      this.#loadedPlugins = []
      this.#providersCache = []
      this.#providersById.clear()
      this.#routeToProvider.clear()
      return []
    }
    await this.ensureHost()
    return this.refreshProviders()
  }

  async #startHost() {
    fs.mkdirSync(this.#rootDir, { recursive: true, mode: 0o700 })
    fs.mkdirSync(this.pluginsDir, { recursive: true, mode: 0o755 })
    const list = this.readList()
    const items = []
    for (const entry of list.plugins) {
      if (entry.off) continue
      const target = this.targetOf(entry.spec)
      items.push({
        spec: entry.spec,
        target,
        options: entry.options,
      })
    }

    const child = spawn(
      process.execPath,
      ['--import', BUN_SHIM, '--experimental-strip-types', HOST_JS],
      {
        cwd: this.#rootDir,
        env: { ...process.env },
        stdio: ['pipe', 'pipe', 'pipe'],
      },
    )
    child.unref()
    this.#child = child

    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (text) => {
      for (const line of String(text).split(/\r?\n/)) {
        if (line.trim()) this.#log(line.trim())
      }
    })

    const rl = readline.createInterface({ input: child.stdout, terminal: false })
    this.#rl = rl
    rl.on('line', (line) => this.#onLine(line))

    child.on('close', (code) => {
      if (this.#child !== child) return
      this.#child = null
      this.#rl = null
      this.#initPromise = null
      const err = new Error(`Magpie plugin host exited (${code ?? 'signal'})`)
      for (const [, p] of this.#pending) {
        p.reject(err)
      }
      this.#pending.clear()
    })

    const initRes = await this.#sendRpc('init', {
      authPath: this.authPath,
      piPath: PI_JS,
      directory: this.#rootDir,
      config: list.config ?? {},
      prefer: list.prefer ?? {},
      options: this.readOptions(),
      plugins: items,
    })
    this.#loadedPlugins = Array.isArray(initRes?.plugins) ? initRes.plugins : []
    const brokenNonCommunity = new Set(
      this.#loadedPlugins
        .filter(
          (l) =>
            l?.error &&
            !String(l.spec ?? '').startsWith(DIST_SCOPE) &&
            (!Array.isArray(l.provides) || l.provides.length === 0),
        )
        .map((l) => l.spec),
    )
    if (brokenNonCommunity.size > 0) {
      const cleaned = list.plugins.filter((p) => !brokenNonCommunity.has(p.spec))
      if (cleaned.length !== list.plugins.length) {
        this.saveList({ ...list, plugins: cleaned })
      }
    }
    return this.#loadedPlugins
  }

  #stopHost() {
    const child = this.#child
    this.#child = null
    this.#rl?.close()
    this.#rl = null
    this.#initPromise = null
    const stopErr = new Error('Magpie plugin host stopped')
    for (const [, p] of this.#pending) {
      p.reject(stopErr)
    }
    this.#pending.clear()
    if (child && child.exitCode === null) {
      try {
        child.stdin.end()
      } catch {}
      setTimeout(() => {
        if (child.exitCode === null) child.kill('SIGKILL')
      }, 1500).unref?.()
    }
  }

  #writeLine(obj) {
    if (!this.#child || !this.#child.stdin.writable) {
      throw new Error('Magpie plugin host is not running')
    }
    this.#child.stdin.write(`${JSON.stringify(obj)}\n`)
  }

  #onLine(line) {
    if (!line || !line.trim()) return
    let msg
    try {
      msg = JSON.parse(line)
    } catch {
      return
    }
    if (msg.id !== undefined) {
      const pending = this.#pending.get(msg.id)
      if (!pending) return
      if (pending.stream) {
        if (msg.event === 'head') {
          pending.onHead?.(msg.status, msg.headers)
          return
        }
        const chunkB64 = msg.event === 'chunk' ? msg.data : msg.chunk
        if (typeof chunkB64 === 'string') {
          const buf = Buffer.from(chunkB64, 'base64')
          pending.chain = pending.chain.then(async () => {
            await pending.onChunk?.(buf)
            try {
              this.#writeLine({ method: 'credit', params: { id: msg.id, n: buf.length + FRAME_OVERHEAD } })
            } catch {}
          })
          return
        }
        this.#pending.delete(msg.id)
        pending.chain
          .then(() => {
            if (msg.error) pending.reject(new Error(msg.error.message || 'Plugin fetch failed'))
            else pending.resolve(msg.result)
          })
          .catch(pending.reject)
        return
      }
      this.#pending.delete(msg.id)
      if (msg.error) {
        pending.reject(new Error(msg.error.message || 'Plugin host RPC failed'))
      } else {
        pending.resolve(msg.result)
      }
      return
    }
    // Spontaneous event from `host.js`
    if (msg.event === 'auth' || msg.event === 'signIn' || msg.event === 'reload') {
      this.#onChange(msg)
    } else if (msg.event === 'log' && msg.message) {
      this.#log(msg.message)
    }
  }

  #sendRpc(method, params = {}, { signal } = {}) {
    const id = this.#nextId++
    return new Promise((resolve, reject) => {
      if (signal?.aborted) {
        reject(new DOMException('Aborted', 'AbortError'))
        return
      }
      const onAbort = () => {
        this.#pending.delete(id)
        try {
          this.#writeLine({ method: 'abort', params: { id } })
        } catch {}
        reject(new DOMException('Aborted', 'AbortError'))
      }
      signal?.addEventListener('abort', onAbort, { once: true })
      this.#pending.set(id, {
        resolve: (val) => {
          signal?.removeEventListener('abort', onAbort)
          resolve(val)
        },
        reject: (err) => {
          signal?.removeEventListener('abort', onAbort)
          reject(err)
        },
      })
      try {
        this.#writeLine({ id, method, params })
      } catch (err) {
        this.#pending.delete(id)
        signal?.removeEventListener('abort', onAbort)
        reject(err)
      }
    })
  }

  async call(method, params = {}, options = {}) {
    await this.ensureHost()
    return this.#sendRpc(method, params, options)
  }

  async fetchStream(params, { signal, onHead, onChunk } = {}) {
    await this.ensureHost()
    const id = this.#nextId++
    return new Promise((resolve, reject) => {
      if (signal?.aborted) {
        reject(new DOMException('Aborted', 'AbortError'))
        return
      }
      const onAbort = () => {
        this.#pending.delete(id)
        try {
          this.#writeLine({ method: 'abort', params: { id } })
        } catch {}
        reject(new DOMException('Aborted', 'AbortError'))
      }
      signal?.addEventListener('abort', onAbort, { once: true })
      this.#pending.set(id, {
        stream: true,
        chain: Promise.resolve(),
        onHead,
        onChunk,
        resolve: (val) => {
          signal?.removeEventListener('abort', onAbort)
          resolve(val)
        },
        reject: (err) => {
          signal?.removeEventListener('abort', onAbort)
          reject(err)
        },
      })
      try {
        this.#writeLine({
          id,
          method: 'fetch',
          params: { ...params, window: DEFAULT_STREAM_WINDOW },
        })
      } catch (err) {
        this.#pending.delete(id)
        signal?.removeEventListener('abort', onAbort)
        reject(err)
      }
    })
  }

  // ── Providers & Options ───────────────────────────────────────────────────

  async refreshProviders({ signal } = {}) {
    if (!this.hasConfiguredPlugins()) {
      this.#providersCache = []
      this.#providersById.clear()
      this.#routeToProvider.clear()
      return []
    }
    const list = await this.call('providers', {}, { signal })
    const rows = Array.isArray(list) ? list : []
    this.#providersCache = rows
    this.#providersById.clear()
    this.#routeToProvider.clear()
    for (const row of rows) {
      if (row && typeof row.id === 'string') {
        this.#providersById.set(row.id, row)
        this.#routeToProvider.set(toPiAiRouteId(row.id), row.id)
      }
    }
    return rows
  }

  getCachedProviders() {
    return this.#providersCache
  }

  getProvider(providerId) {
    return this.#providersById.get(providerId)
  }

  getLoadedPlugins() {
    return this.#loadedPlugins
  }

  async setProviderOption(providerId, key, value) {
    const all = this.readOptions()
    all[providerId] = { ...(all[providerId] ?? {}), [key]: Boolean(value) }
    this.saveOptions(all)
    if (this.#child) {
      await this.call('setProviderOptions', { options: all })
      await this.refreshProviders()
    }
    return all[providerId]
  }

  getProviderOptions(providerId, declaredOptions = []) {
    const stored = this.readOptions()?.[providerId] ?? {}
    const out = []
    for (const o of declaredOptions) {
      out.push({
        key: o.key,
        label: o.labels?.zh || o.label,
        labelEn: o.labels?.en || o.label,
        description: o.descriptions?.zh || o.description || undefined,
        descriptionEn: o.descriptions?.en || o.description || undefined,
        confirm: o.confirms?.zh || o.confirm || undefined,
        confirmEn: o.confirms?.en || o.confirm || undefined,
        filtersModels: o.filtersModels === true,
        value: typeof stored[o.key] === 'boolean' ? stored[o.key] : o.default === true,
      })
    }
    return out
  }

  // ── Marketplace & Package Installation ────────────────────────────────────

  builtinMarket() {
    const raw = readJSON(BUILTIN_MARKET_PATH, { plugins: [] })
    return Array.isArray(raw?.plugins) ? raw.plugins : []
  }

  async fetchMarketListings({ force = false } = {}) {
    const now = Date.now()
    if (!force && this.#marketCache && now - this.#marketFetchedAt < 10 * 60 * 1000) {
      return this.#marketCache
    }
    const builtin = this.builtinMarket()
    for (const url of MARKET_URLS) {
      try {
        const res = await this.#fetchFn(url, { signal: AbortSignal.timeout(5000) })
        if (res.ok) {
          const data = await res.json()
          if (Array.isArray(data?.plugins) && data.plugins.length > 0) {
            this.#marketCache = data.plugins
            this.#marketFetchedAt = now
            return this.#marketCache
          }
        }
      } catch {}
    }
    this.#marketCache = builtin
    this.#marketFetchedAt = now
    return builtin
  }

  /**
   * Lists subscription plugins from Magpie's marketplace merged with installed
   * plugins from `plugins.json`.
   */
  async market() {
    const listings = await this.fetchMarketListings()
    const installedList = this.readList().plugins
    if (this.hasConfiguredPlugins() && !this.#child) {
      try {
        await this.reloadHost()
      } catch (err) {
        this.#log(`loading configured plugins failed: ${err?.message ?? err}`)
      }
    }
    const loadedBySpec = new Map(this.#loadedPlugins.map((l) => [this.packageNameOf(l.spec), l]))
    const installedByPkg = new Map(installedList.map((e) => [this.packageNameOf(e.spec), e]))

    const out = []
    const seenPkgs = new Set()

    for (const item of listings) {
      // Only show provider plugins by default (or middleware if already installed)
      if (item.kind && item.kind !== 'provider' && !installedByPkg.has(item.package)) continue
      seenPkgs.add(item.package)
      const inst = installedByPkg.get(item.package)
      const loaded = loadedBySpec.get(item.package)
      out.push({
        package: item.package,
        name: item.name || shortPluginName(item.package),
        icon: item.icon || undefined,
        providers: Array.isArray(item.providers) ? item.providers : loaded?.provides ?? [],
        community: item.community === true,
        summaryZh: item.summary?.zh || item.summary?.en || '',
        summaryEn: item.summary?.en || item.summary?.zh || '',
        installed: Boolean(inst && !inst.off),
        version: inst ? this.installedVersionOf(inst.spec) : undefined,
        error: loaded?.error || undefined,
      })
    }

    // Include any custom/third-party plugins the user installed outside the catalog
    for (const entry of installedList) {
      const pkg = this.packageNameOf(entry.spec)
      if (seenPkgs.has(pkg)) continue
      seenPkgs.add(pkg)
      const loaded = loadedBySpec.get(pkg)
      out.push({
        package: pkg,
        name: shortPluginName(pkg),
        providers: loaded?.provides ?? [],
        community: false,
        summaryZh: entry.spec,
        summaryEn: entry.spec,
        installed: !entry.off,
        version: this.installedVersionOf(entry.spec),
        error: loaded?.error || undefined,
      })
    }

    return { plugins: out }
  }

  /** Resolves a short name (e.g. `workbuddy`) or package spec to an installable spec. */
  async resolveSpec(rawSpec) {
    const trimmed = String(rawSpec ?? '').trim()
    if (!trimmed) throw new Error('插件包名不能为空')
    if (trimmed.startsWith('npm:')) {
      const rest = trimmed.slice(4).trim()
      if (!PKG_NAME_RE.test(this.packageNameOf(rest))) throw new Error(`无效的 npm 包名: ${rest}`)
      return rest
    }
    if (isPathSpec(trimmed) || isGitSpec(trimmed) || trimmed.startsWith('@')) {
      return trimmed
    }
    let name = trimmed
    let version = ''
    const at = trimmed.lastIndexOf('@')
    if (at > 0) {
      name = trimmed.slice(0, at)
      version = trimmed.slice(at)
    }
    const key = name.toLowerCase().trim()
    const listings = await this.fetchMarketListings()
    const fuzzyMatches = []
    for (const l of listings) {
      if (!l.community) continue
      const names = [
        l.package,
        l.package.includes('/') ? l.package.slice(l.package.indexOf('/') + 1) : l.package,
        shortPluginName(l.package),
        l.name,
        l.name?.replace(/\s+/g, ''),
        l.name?.replace(/\s+/g, '-'),
        l.replaces,
        ...(l.providers ?? []),
      ]
        .filter(Boolean)
        .map((s) => String(s).toLowerCase())
      if (names.includes(key)) {
        return l.package + version
      }
      if (key.length >= 2 && names.some((n) => n.startsWith(key) || n.includes(key))) {
        fuzzyMatches.push(l.package)
      }
    }
    if (fuzzyMatches.length === 1) {
      return fuzzyMatches[0] + version
    }
    if (PKG_NAME_RE.test(name) && (/^(?:opencode|magpie)-|-(?:auth|plugin)$/.test(name) || name.includes('/'))) {
      return trimmed
    }
    throw new Error(`未找到名为 "${trimmed}" 的订阅插件`)
  }

  installPlugin(rawSpec) {
    const run = this.#installQueue.then(() => this.#doInstall(rawSpec))
    this.#installQueue = run.catch(() => {})
    return run
  }

  async #doInstall(rawSpec) {
    const spec = await this.resolveSpec(rawSpec)
    fs.mkdirSync(this.pluginsDir, { recursive: true, mode: 0o755 })
    const pjPath = path.join(this.pluginsDir, 'package.json')
    if (!fs.existsSync(pjPath)) {
      writeAtomicJSON(pjPath, { name: 'dsh-magpie-plugins', private: true, dependencies: {} })
    }

    if (isPathSpec(spec)) {
      const target = this.targetOf(spec)
      if (!fs.existsSync(target)) throw new Error(`本地插件路径不存在: ${target}`)
    } else if (this.#runInstaller) {
      await this.#runInstaller(spec, this.pluginsDir)
    } else {
      const installSpec = !isGitSpec(spec) && this.packageNameOf(spec) === spec ? `${spec}@latest` : spec
      try {
        await this.#runNpm(['install', '--save', '--ignore-scripts', '--no-audit', '--no-fund', installSpec])
      } catch (npmErr) {
        if (this.packageNameOf(spec).startsWith(DIST_SCOPE)) {
          await this.#installFromDistBranch(this.packageNameOf(spec))
        } else {
          throw npmErr
        }
      }
    }

    const list = this.readList()
    const prevPlugins = list.plugins.map((p) => ({ ...p }))
    const pkgName = this.packageNameOf(spec)
    const idx = list.plugins.findIndex((p) => p.spec === spec || this.packageNameOf(p.spec) === pkgName)
    const hadPkg = idx >= 0
    if (idx >= 0) {
      list.plugins[idx] = { ...list.plugins[idx], spec, off: false }
    } else {
      list.plugins.push({ spec })
    }
    this.saveList(list)

    let providers
    try {
      providers = await this.reloadHost()
    } catch (reloadErr) {
      this.saveList({ ...list, plugins: prevPlugins })
      throw reloadErr
    }
    const loaded = this.#loadedPlugins.find((l) => l.spec === spec || this.packageNameOf(l.spec) === pkgName)
    if (loaded?.error) {
      this.saveList({ ...list, plugins: prevPlugins })
      if (!hadPkg && !isPathSpec(spec) && !this.#runInstaller) {
        try {
          await this.#runNpm(['uninstall', '--ignore-scripts', '--no-audit', '--no-fund', pkgName])
        } catch {}
      }
      await this.reloadHost().catch(() => {})
      throw new Error(`插件加载失败: ${loaded.error}`)
    }
    // Prune any stale broken entries from earlier failed attempts so they don't linger in plugins.json.
    const brokenSpecs = new Set(
      this.#loadedPlugins
        .filter((l) => l.error && (!Array.isArray(l.provides) || l.provides.length === 0))
        .map((l) => l.spec),
    )
    if (brokenSpecs.size > 0) {
      const cleaned = list.plugins.filter((p) => !brokenSpecs.has(p.spec))
      if (cleaned.length !== list.plugins.length) {
        this.saveList({ ...list, plugins: cleaned })
      }
    }
    return {
      spec,
      package: pkgName,
      version: this.installedVersionOf(spec),
      providers: providers.filter((p) => p.spec === spec || this.packageNameOf(p.spec) === pkgName).map((p) => p.id),
    }
  }

  removePlugin(rawSpec) {
    const run = this.#installQueue.then(() => this.#doRemove(rawSpec))
    this.#installQueue = run.catch(() => {})
    return run
  }

  async #doRemove(rawSpec) {
    const spec = await this.resolveSpec(rawSpec).catch(() => String(rawSpec ?? '').trim())
    const pkgName = this.packageNameOf(spec)
    const list = this.readList()
    if (this.hasConfiguredPlugins() && this.#providersCache.length === 0) {
      await this.refreshProviders().catch(() => [])
    }
    const removedProviders = this.#providersCache
      .filter((p) => p.spec === spec || this.packageNameOf(p.spec) === pkgName)
      .map((p) => p.id)

    for (const id of removedProviders) {
      try {
        await this.call('signOut', { provider: id })
      } catch {}
    }

    list.plugins = list.plugins.filter((p) => p.spec !== spec && this.packageNameOf(p.spec) !== pkgName)
    this.saveList(list)

    if (!isPathSpec(spec) && !this.#runInstaller) {
      try {
        await this.#runNpm(['uninstall', '--ignore-scripts', '--no-audit', '--no-fund', pkgName])
      } catch {}
    }

    await this.reloadHost()
    return { removedProviders }
  }

  async #runNpm(args) {
    return new Promise((resolve, reject) => {
      const npmBin = process.platform === 'win32' ? 'npm.cmd' : 'npm'
      const child = spawn(npmBin, args, {
        cwd: this.pluginsDir,
        env: { ...process.env, npm_config_loglevel: 'error' },
        stdio: ['ignore', 'pipe', 'pipe'],
      })
      const out = []
      child.stdout.on('data', (c) => out.push(c))
      child.stderr.on('data', (c) => out.push(c))
      child.on('error', reject)
      child.on('close', (code) => {
        if (code === 0) resolve()
        else reject(new Error(Buffer.concat(out).toString('utf8').trim() || `npm ${args[0]} failed (${code})`))
      })
    })
  }

  /** Fallback installer from `magpie-community/plugins@dist` with SHA-512 verification. */
  async #installFromDistBranch(pkgName) {
    let indexData
    let chosenBase
    for (const base of DIST_BASES) {
      try {
        const res = await this.#fetchFn(`${base}/index.json`, { signal: AbortSignal.timeout(15000) })
        if (res.ok) {
          indexData = await res.json()
          chosenBase = base
          break
        }
      } catch {}
    }
    const pkg = indexData?.packages?.[pkgName]
    if (!pkg || !pkg.latest || !pkg.versions?.[pkg.latest]) {
      throw new Error(`无法从 npm 或社区源获取插件 ${pkgName}`)
    }
    const ver = pkg.versions[pkg.latest]
    if (!DIST_FILE_RE.test(ver.file)) {
      throw new Error(`非法的插件包路径: ${ver.file}`)
    }
    const tgzRes = await this.#fetchFn(`${chosenBase}/${ver.file}`, { signal: AbortSignal.timeout(30000) })
    if (!tgzRes.ok) throw new Error(`下载插件包失败 (${tgzRes.status})`)
    const bytes = Buffer.from(await tgzRes.arrayBuffer())
    const sha = `sha512-${createHash('sha512').update(bytes).digest('base64')}`
    if (sha !== ver.integrity) {
      throw new Error(`插件包 SHA-512 校验失败`)
    }
    const distDir = path.join(this.pluginsDir, 'dist')
    fs.mkdirSync(distDir, { recursive: true, mode: 0o755 })
    const fileName = path.basename(ver.file)
    const tgzPath = path.join(distDir, fileName)
    fs.writeFileSync(tgzPath, bytes, { mode: 0o644 })
    await this.#runNpm(['install', '--save', '--ignore-scripts', '--no-audit', '--no-fund', `./dist/${fileName}`])
  }

  dispose() {
    this.#disposed = true
    this.#stopHost()
    if (this.#server) {
      try {
        this.#server.close()
      } catch {}
      this.#server = null
      this.#serverPort = 0
    }
  }
}
