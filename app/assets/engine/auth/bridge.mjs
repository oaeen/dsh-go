// SPDX-License-Identifier: MIT
//
// dsh-app auth bridge: the state machine behind the `appAuth` Remote service.
//
// DSH 0.2.1 already ships subscription sign-in. The built-in `llm-pi-ai` adapter
// registers one `ctx.authorization` flow per pi-ai provider that has a login
// (`llm-pi-ai/openai-codex` for ChatGPT, `llm-pi-ai/anthropic` for Claude), and
// the flow stores pi-ai's OAuth grant through `ctx.credentials` (credentials-local
// writes it to `$DSH_HOME/.credentials.yaml` as `{kind: grant, payload}`). What
// 0.2.1 lacks is a client-facing way to start one, so this module does what the
// DeepSeek account platform does internally (`ctx.authorization.begin`) and turns
// the flow's notices and prompts into a small polled state machine:
//
//   begin → starting → open | device | prompt → done | failed | cancelled
//                       (answer() replies to a pending paste prompt)
//
// After a successful sign-in it declares the catalog route
// (`llm-pi-ai.providers.<id>`) so the provider's models show up; sign-out removes
// the route and deletes the grant. Token refresh stays with pi-ai, per request.
//
// This file has no imports from DSH: `index.mjs` wires it into the host, and the
// tests drive it with a fake context.

import { randomUUID } from 'node:crypto'
import { createServer } from 'node:net'

import {
  MAGPIE_PLUGIN_KEY_ENV,
  MagpieManager,
  extractDeviceCode,
  toPiAiModels,
  toPiAiProtocol,
  toPiAiRouteId,
} from './magpie.mjs'

/** The subscriptions this bridge signs in to, keyed by pi-ai provider id (= llm-pi-ai route id). */
export const PROVIDERS = Object.freeze({
  'openai-codex': Object.freeze({
    displayName: 'ChatGPT',
    // pi-ai's Codex login listens on this fixed port only; when it cannot bind
    // it, the login continues with the pasted redirect URL alone.
    callbackPort: 1455,
  }),
  anthropic: Object.freeze({
    displayName: 'Claude',
    // pi-ai's Claude login prefers 53692 and falls back to any free port (the
    // redirect URI names the port it got), so a callback is always possible.
    callbackPort: undefined,
  }),
})

/** Owner scope of pi-ai's credential records (`credentialKey('llm-pi-ai', id)`). */
const RECORD_SCOPE = 'llm-pi-ai'
/** Settings namespace (loader entry id) of the llm-pi-ai adapter in the base bundle. */
const SETTINGS_NS = 'llm-pi-ai'

/** An attempt that has not finished after this long is withdrawn. */
export const ATTEMPT_TTL_MS = 10 * 60 * 1000
/** A finished attempt stays readable this long, so a late poll still sees how it ended. */
const FINISHED_KEEP_MS = 10 * 60 * 1000
const MAX_KEPT_ATTEMPTS = 16
const MAX_ANSWER_LENGTH = 8192

/** Product copy shown by the app (Chinese, short). */
export const COPY = Object.freeze({
  starting: '正在准备登录…',
  open: '在浏览器里完成登录',
  device: '在打开的网页里输入下面的代码',
  prompt: '在浏览器里登录后，把地址栏里的完整网址复制下来，粘贴到这里',
  finishing: '正在完成登录…',
})

export const ERRORS = Object.freeze({
  cancelled: '登录已取消',
  timeout: '登录超时了，再试一次',
  denied: '授权被拒绝了，再试一次',
  network: '网络连不上，检查网络后再试',
  badPaste: '粘贴的内容不对，再试一次',
  unavailable: '引擎暂时不能登录，重启引擎后再试',
  busy: '上一次登录还没结束，稍后再试',
  generic: '授权没有完成，再试一次',
  expired: '这次登录已失效，请重新开始',
  signOut: '退出登录没有完成，再试一次',
})

/**
 * Fallback for the host's `RemoteError` (same constructor). The Gateway
 * recognizes Remote failures structurally (`isDSHRemoteError`), so `code` and
 * `message` reach the client either way.
 */
export class BridgeError extends Error {
  constructor(code, message, details = {}) {
    super(message)
    this.name = 'RemoteError'
    this.code = code
    this.details = details
    this.isDSHRemoteError = true
  }
}

const TERMINAL = new Set(['done', 'failed', 'cancelled'])

const isObject = (value) => typeof value === 'object' && value !== null && !Array.isArray(value)

export const recordKeyFor = (provider) => `${RECORD_SCOPE}/${provider}`

/** Whether a TCP port can be bound right now (pi-ai binds it a moment later). */
export function portIsFree(port, host = process.env.PI_OAUTH_CALLBACK_HOST || '127.0.0.1') {
  return new Promise((resolve) => {
    const server = createServer()
    server.unref()
    server.once('error', () => resolve(false))
    server.listen({ port, host, exclusive: true }, () => server.close(() => resolve(true)))
  })
}

/** Strips anything token-shaped and bounds the length, for stderr diagnostics. */
export function redact(text) {
  return String(text)
    .replace(/eyJ[\w-]+\.[\w-]+\.[\w-]*/g, '<jwt>')
    .replace(/[A-Za-z0-9_-]{32,}/g, '<redacted>')
    .slice(0, 600)
}

/** Host of a URL for logs; auth URLs carry PKCE state, so never the whole thing. */
function hostOf(url) {
  try {
    return new URL(url).host
  } catch {
    return '?'
  }
}

function causes(error) {
  const chain = []
  for (let e = error, depth = 0; e != null && depth < 8; e = e.cause, depth++) chain.push(e)
  return chain
}

/** One short product sentence for a failed attempt; the details go to stderr. */
export function describeFailure(error) {
  const chain = causes(error)
  const codes = chain.map((e) => (typeof e?.code === 'string' ? e.code : '')).filter(Boolean)
  const text = chain.map((e) => (e instanceof Error ? `${e.name} ${e.message}` : String(e))).join(' | ')
  if (codes.some((c) => c === 'NO_FLOW' || c === 'UNKNOWN_METHOD' || c === 'NO_CREDENTIAL_STORE')) return ERRORS.unavailable
  if (codes.includes('ALREADY_IN_FLIGHT')) return ERRORS.busy
  if (/authorization failed/i.test(text)) return ERRORS.denied
  if (/state mismatch|missing authorization code/i.test(text)) return ERRORS.badPaste
  const network = ['ENOTFOUND', 'EAI_AGAIN', 'ECONNREFUSED', 'ECONNRESET', 'ETIMEDOUT', 'ENETUNREACH', 'EHOSTUNREACH']
  if (codes.some((c) => network.includes(c) || c.startsWith('UND_ERR_'))) return ERRORS.network
  if (/fetch failed|TimeoutError|network/i.test(text)) return ERRORS.network
  return ERRORS.generic
}

/** Payload of a JWT, without verification (only to label the account). */
function jwtClaims(token) {
  const part = typeof token === 'string' ? token.split('.')[1] : undefined
  if (!part) return undefined
  try {
    const claims = JSON.parse(Buffer.from(part, 'base64url').toString('utf8'))
    return isObject(claims) ? claims : undefined
  } catch {
    return undefined
  }
}

/**
 * Who is signed in, when the grant says. A ChatGPT access token is a JWT whose
 * claims carry the email and plan; a Claude token is opaque.
 */
export function accountOf(provider, payload) {
  if (provider !== 'openai-codex' || !isObject(payload)) return undefined
  const claims = jwtClaims(payload.access)
  if (!claims) return undefined
  const profile = claims['https://api.openai.com/profile']
  const email = (isObject(profile) ? profile.email : undefined) ?? claims.email
  if (typeof email === 'string' && email.includes('@')) return email
  const auth = claims['https://api.openai.com/auth']
  const plan = isObject(auth) ? auth.chatgpt_plan_type : undefined
  if (typeof plan === 'string' && plan.length > 0) return `ChatGPT ${plan[0].toUpperCase()}${plan.slice(1)}`
  return undefined
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms).unref?.())

/** Resolves when [promise] settles or after [ms], whichever comes first. */
const settleWithin = (promise, ms) => Promise.race([Promise.resolve(promise).catch(() => {}), sleep(ms)])

/** One sign-in attempt. Only the bridge mutates it. */
class Attempt {
  constructor(id, provider) {
    this.id = id
    this.provider = provider
    this.phase = 'starting'
    this.message = COPY.starting
    this.url = undefined
    this.userCode = undefined
    this.placeholder = undefined
    this.options = undefined
    this.error = undefined
    /** The paste prompt pi-ai is waiting on, if any: {resolve, reject}. */
    this.pending = undefined
    /** Whether a browser redirect can reach pi-ai's callback server. */
    this.callbackLikely = true
    this.controller = new AbortController()
    this.cancelRequested = false
    this.timedOut = false
    this.timer = undefined
    this.finishedAt = undefined
    this.done = Promise.resolve()
  }

  get live() {
    return this.finishedAt === undefined
  }

  set(phase, message) {
    this.phase = phase
    this.message = message
  }

  /** The wire view (`appAuth/poll`): JSON only, no undefined members. */
  view() {
    const view = { phase: this.phase }
    if (!TERMINAL.has(this.phase)) {
      if (this.url !== undefined && this.phase !== 'starting') view.url = this.url
      if (this.userCode !== undefined && this.phase === 'device') view.userCode = this.userCode
      if (this.placeholder !== undefined && this.pending !== undefined) view.placeholder = this.placeholder
      if (this.options !== undefined && this.pending !== undefined) view.options = this.options
    }
    if (this.message !== undefined) view.message = this.message
    if (this.error !== undefined) view.error = this.error
    return view
  }
}

/**
 * The `appAuth` service logic.
 *
 * `get(name)` returns a live host service (`authorization`, `credentials`,
 * `settings`) or undefined. `RemoteError` is the host's Remote failure class.
 */
export class AuthBridge {
  #get
  #log
  #RemoteError
  #now
  #ttlMs
  #probePort
  #settingsNs
  #magpie = null
  #attempts = new Map()
  #liveByProvider = new Map()
  /** Route and grant changes run one at a time, so a repair cannot interleave with a sign-out. */
  #routeQueue = Promise.resolve()

  constructor({
    get,
    log = (line) => console.error(`[dsh-app auth] ${line}`),
    RemoteError = BridgeError,
    now = Date.now,
    ttlMs = ATTEMPT_TTL_MS,
    probePort = portIsFree,
    settingsNs = SETTINGS_NS,
    magpie = null,
  }) {
    this.#get = get
    this.#log = log
    this.#RemoteError = RemoteError
    this.#now = now
    this.#ttlMs = ttlMs
    this.#probePort = probePort
    this.#settingsNs = settingsNs
    if (magpie instanceof MagpieManager) {
      this.#magpie = magpie
    } else if (magpie && typeof magpie === 'object') {
      this.#magpie = new MagpieManager({ log, ...magpie })
    } else if (magpie === true) {
      this.#magpie = new MagpieManager({ log })
    }
  }

  #ensureMagpie() {
    if (!this.#magpie) {
      this.#magpie = new MagpieManager({ log: this.#log })
    }
    return this.#magpie
  }

  // ── Remote methods ──────────────────────────────────────────────────────

  /** `appAuth/list`: built-in and installed plugin subscriptions, signed in or not. */
  async list() {
    const credentials = this.#get('credentials')
    const providers = []
    for (const id of Object.keys(PROVIDERS)) {
      let record
      try {
        record = await credentials?.readRecord(recordKeyFor(id))
      } catch (error) {
        this.#log(`${id}: reading the grant failed: ${redact(error?.message ?? error)}`)
      }
      const signedIn = record?.kind === 'grant' && record.payload !== undefined
      const entry = { id, signedIn }
      if (signedIn) {
        const account = accountOf(id, record.payload)
        if (account !== undefined) entry.account = account
        // Signed in means its models are offered: repair a route a settings
        // restore (or a failed write after sign-in) left out.
        try {
          await this.#serialized(async () => {
            if ((await credentials.readRecord(recordKeyFor(id)))?.kind === 'grant') await this.#ensureRoute(id)
          })
        } catch (error) {
          this.#log(`${id}: declaring the route failed: ${redact(error?.message ?? error)}`)
        }
      }
      providers.push(entry)
    }

    if (this.#magpie?.hasConfiguredPlugins()) {
      try {
        const pluginProviders = await this.#magpie.refreshProviders()
        const signedInRouteIds = new Set()
        for (const p of pluginProviders) {
          if (!p || typeof p.id !== 'string' || Object.hasOwn(PROVIDERS, p.id)) continue
          const signedIn = Boolean(p.signedIn)
          const routeId = toPiAiRouteId(p.id)
          const entry = {
            id: p.id,
            displayName: p.name || p.id,
            pluginSpec: p.spec,
            signedIn,
          }
          if (signedIn && typeof p.accountId === 'string' && p.accountId.trim()) {
            entry.account = p.accountId.trim()
          }
          if (p.usage) entry.supportsUsage = true
          if (p.checkin) entry.supportsCheckin = true
          const opts = this.#magpie.getProviderOptions(p.id, p.options)
          if (opts.length > 0) entry.options = opts

          if (signedIn) {
            signedInRouteIds.add(routeId)
            try {
              await this.#serialized(() => this.#ensurePluginRoute(p))
            } catch (error) {
              this.#log(`${p.id}: declaring plugin route failed: ${redact(error?.message ?? error)}`)
            }
          }
          providers.push(entry)
        }
        try {
          await this.#serialized(() => this.#pruneStalePluginRoutes(signedInRouteIds))
        } catch (error) {
          this.#log(`pruning stale plugin routes failed: ${redact(error?.message ?? error)}`)
        }
      } catch (error) {
        this.#log(`magpie list failed: ${redact(error?.message ?? error)}`)
      }
    }

    return { providers }
  }

  /** `appAuth/begin`: starts a sign-in and returns its id at once; progress is polled. */
  async begin(provider) {
    const isBuiltIn = typeof provider === 'string' && Object.hasOwn(PROVIDERS, provider)
    let spec
    let pluginProvider
    if (isBuiltIn) {
      spec = PROVIDERS[provider]
    } else if (typeof provider === 'string' && this.#magpie) {
      pluginProvider = this.#magpie.getProvider(provider)
      if (!pluginProvider && this.#magpie.hasConfiguredPlugins()) {
        const rows = await this.#magpie.refreshProviders().catch(() => [])
        pluginProvider = rows.find((item) => item.id === provider)
      }
    }
    if (!isBuiltIn && !pluginProvider) {
      throw new this.#RemoteError('app-auth/unknown-provider', '不支持这个登录方式', {})
    }

    this.#prune()
    // Tapping "sign in" again replaces the attempt in flight (DSH runs one per key).
    const previous = this.#liveByProvider.get(provider)
    if (previous !== undefined) {
      previous.cancelRequested = true
      this.#abort(previous)
      await settleWithin(previous.done, 5000)
    }
    const attempt = new Attempt(randomUUID(), provider)
    this.#attempts.set(attempt.id, attempt)
    this.#liveByProvider.set(provider, attempt)
    attempt.timer = setTimeout(() => {
      attempt.timedOut = true
      this.#abort(attempt)
    }, this.#ttlMs)
    attempt.timer.unref?.()
    attempt.done = isBuiltIn
      ? this.#run(attempt, spec, previous !== undefined)
      : this.#runPluginAttempt(attempt, provider)
    return { attemptId: attempt.id }
  }

  /** `appAuth/poll`: where the attempt is. An unknown id reads as failed (e.g. after an engine restart). */
  poll(attemptId) {
    this.#prune()
    const attempt = this.#attempts.get(String(attemptId))
    if (attempt === undefined) return { phase: 'failed', error: ERRORS.expired }
    return attempt.view()
  }

  /** `appAuth/answer`: the pasted code, redirect URL, or selected option for a pending prompt. */
  answer(attemptId, value) {
    const attempt = this.#attempts.get(String(attemptId))
    if (attempt === undefined || !attempt.live) throw new this.#RemoteError('app-auth/attempt-over', ERRORS.expired, {})
    const pending = attempt.pending
    if (pending === undefined) throw new this.#RemoteError('app-auth/not-waiting', '现在不需要粘贴内容', {})
    const text = typeof value === 'string' ? value.trim() : ''
    if (text.length === 0) throw new this.#RemoteError('app-auth/empty-answer', '先粘贴授权信息', {})
    if (text.length > MAX_ANSWER_LENGTH) throw new this.#RemoteError('app-auth/answer-too-long', ERRORS.badPaste, {})
    attempt.pending = undefined
    attempt.placeholder = undefined
    attempt.options = undefined
    attempt.error = undefined
    attempt.set('starting', COPY.finishing)
    pending.resolve(text)
    return {}
  }

  /** `appAuth/cancel`: abandons an attempt; a no-op once it finished. */
  cancel(attemptId) {
    const attempt = this.#attempts.get(String(attemptId))
    if (attempt?.live) {
      attempt.cancelRequested = true
      this.#abort(attempt)
    }
    return {}
  }

  /** `appAuth/signOut`: removes the route (when the bridge owns it) and deletes the grant. */
  async signOut(provider) {
    const isBuiltIn = typeof provider === 'string' && Object.hasOwn(PROVIDERS, provider)
    let pluginProvider
    if (!isBuiltIn && typeof provider === 'string' && this.#magpie) {
      pluginProvider = this.#magpie.getProvider(provider)
      if (!pluginProvider && this.#magpie.hasConfiguredPlugins()) {
        const rows = await this.#magpie.refreshProviders().catch(() => [])
        pluginProvider = rows.find((item) => item.id === provider)
      }
    }
    if (!isBuiltIn && !pluginProvider) {
      throw new this.#RemoteError('app-auth/unknown-provider', '不支持这个登录方式', {})
    }

    const live = this.#liveByProvider.get(provider)
    if (live !== undefined) {
      live.cancelRequested = true
      this.#abort(live)
      await settleWithin(live.done, 5000)
    }
    try {
      await this.#serialized(async () => {
        if (isBuiltIn) {
          // Route first: a grant without a route is repaired by list(); a route
          // without a grant would offer models that cannot answer.
          await this.#removeRoute(provider)
          const credentials = this.#get('credentials')
          if (credentials === undefined) throw new Error('credentials service is absent')
          const key = recordKeyFor(provider)
          const record = await credentials.readRecord(key)
          // Only an OAuth grant is ours to remove; an api-key record is the user's.
          if (record?.kind === 'grant') await credentials.deleteRecord(key)
        } else {
          await this.#removePluginRoute(provider)
          await this.#magpie.call('signOut', { provider })
          await this.#magpie.refreshProviders()
        }
      })
      this.#log(`${provider}: signed out`)
    } catch (error) {
      this.#log(`${provider}: sign-out failed: ${redact(error?.stack ?? error)}`)
      throw new this.#RemoteError('app-auth/sign-out-failed', ERRORS.signOut, {})
    }
    return {}
  }

  /** `appAuth/usage`: queries subscription quota/usage windows from a plugin provider. */
  async usage(provider) {
    if (typeof provider !== 'string' || !provider.trim()) {
      throw new this.#RemoteError('app-auth/unknown-provider', '不支持这个订阅渠道', {})
    }
    const magpie = this.#ensureMagpie()
    try {
      const res = await magpie.call('usage', { provider })
      return res ?? {}
    } catch (error) {
      this.#log(`${provider}: usage failed: ${redact(error?.message ?? error)}`)
      throw new this.#RemoteError('app-auth/usage-failed', error?.message || '获取用量失败', {})
    }
  }

  /** `appAuth/checkin`: runs daily check-in for a plugin provider. */
  async checkin(provider) {
    if (typeof provider !== 'string' || !provider.trim()) {
      throw new this.#RemoteError('app-auth/unknown-provider', '不支持这个订阅渠道', {})
    }
    const magpie = this.#ensureMagpie()
    try {
      const res = await magpie.call('checkin', { provider })
      const outcome = typeof res?.outcome === 'string' ? res.outcome : ''
      const ok = outcome === 'claimed' || outcome === 'done' || res?.ok === true
      return {
        ok,
        outcome: outcome || (ok ? 'claimed' : 'failed'),
        credit: typeof res?.credit === 'number' ? res.credit : 0,
        streak: typeof res?.streak === 'number' ? res.streak : 0,
        message: typeof res?.message === 'string' ? res.message : '',
        until: typeof res?.until === 'string' ? res.until : '',
      }
    } catch (error) {
      this.#log(`${provider}: checkin failed: ${redact(error?.message ?? error)}`)
      throw new this.#RemoteError('app-auth/checkin-failed', error?.message || '签到失败', {})
    }
  }

  /** `appAuth/setOption`: updates a boolean provider option and refreshes its model route. */
  async setOption(provider, key, value) {
    if (typeof provider !== 'string' || !provider.trim() || typeof key !== 'string' || !key.trim()) {
      throw new this.#RemoteError('app-auth/invalid-option', '无效的插件选项', {})
    }
    const magpie = this.#ensureMagpie()
    try {
      await magpie.setProviderOption(provider, key, Boolean(value))
      const p = magpie.getProvider(provider)
      if (p?.signedIn) {
        await this.#serialized(() => this.#ensurePluginRoute(p))
      }
      return {
        options: magpie.getProviderOptions(provider, p?.options ?? []),
      }
    } catch (error) {
      this.#log(`${provider}: setOption failed: ${redact(error?.message ?? error)}`)
      throw new this.#RemoteError('app-auth/option-failed', error?.message || '更新选项失败', {})
    }
  }

  /** `appAuth/market`: lists available and installed Magpie subscription plugins. */
  async market() {
    try {
      return await this.#ensureMagpie().market()
    } catch (error) {
      this.#log(`market failed: ${redact(error?.message ?? error)}`)
      throw new this.#RemoteError('app-auth/market-failed', error?.message || '获取插件市场失败', {})
    }
  }

  /** `appAuth/installPlugin`: installs and loads a Magpie subscription plugin. */
  async installPlugin(spec) {
    const magpie = this.#ensureMagpie()
    try {
      const res = await magpie.installPlugin(spec)
      for (const p of magpie.getCachedProviders()) {
        if (p?.signedIn && !Object.hasOwn(PROVIDERS, p.id)) {
          await this.#serialized(() => this.#ensurePluginRoute(p)).catch((err) => {
            this.#log(`${p.id}: declaring plugin route after install failed: ${redact(err?.message ?? err)}`)
          })
        }
      }
      return res
    } catch (error) {
      this.#log(`installPlugin(${spec}) failed: ${redact(error?.message ?? error)}`)
      throw new this.#RemoteError('app-auth/install-failed', error?.message || '安装订阅插件失败', {})
    }
  }

  /** `appAuth/removePlugin`: signs out, removes routes, and uninstalls a Magpie plugin. */
  async removePlugin(spec) {
    const magpie = this.#ensureMagpie()
    try {
      const res = await magpie.removePlugin(spec)
      for (const id of res.removedProviders ?? []) {
        const live = this.#liveByProvider.get(id)
        if (live !== undefined) {
          live.cancelRequested = true
          this.#abort(live)
          await settleWithin(live.done, 2000)
        }
        await this.#serialized(() => this.#removePluginRoute(id)).catch((err) => {
          this.#log(`${id}: removing plugin route failed: ${redact(err?.message ?? err)}`)
        })
      }
      return res
    } catch (error) {
      this.#log(`removePlugin(${spec}) failed: ${redact(error?.message ?? error)}`)
      throw new this.#RemoteError('app-auth/remove-failed', error?.message || '卸载订阅插件失败', {})
    }
  }

  /** Withdraws every attempt and stops the Magpie plugin host (plugin unload). */
  dispose() {
    for (const attempt of this.#attempts.values()) {
      if (!attempt.live) continue
      attempt.cancelRequested = true
      this.#abort(attempt)
    }
    this.#magpie?.dispose()
  }

  // ── one attempt ─────────────────────────────────────────────────────────

  async #run(attempt, spec, replaced) {
    const { provider } = attempt
    const key = recordKeyFor(provider)
    try {
      const authorization = this.#get('authorization')
      if (authorization?.describe?.(key) === undefined) {
        throw Object.assign(new Error(`no authorization flow for ${key}`), { code: 'NO_FLOW' })
      }
      if (spec.callbackPort !== undefined) {
        // The replaced attempt's callback server closes as its flow unwinds.
        if (replaced) for (let i = 0; i < 15 && !(await this.#probePort(spec.callbackPort)); i++) await sleep(100)
        attempt.callbackLikely = await this.#probePort(spec.callbackPort)
        if (!attempt.callbackLikely) this.#log(`${provider}: port ${spec.callbackPort} is taken; the sign-in falls back to a pasted URL`)
      }
      if (attempt.controller.signal.aborted) throw new Error('withdrawn before start')
      this.#log(`${provider}: sign-in started (${attempt.id})`)
      const outcome = await authorization.begin({
        key,
        method: 'oauth',
        signal: attempt.controller.signal,
        interaction: {
          notify: (notice) => this.#onNotice(attempt, notice),
          prompt: (prompt) => this.#onPrompt(attempt, prompt),
        },
      })
      if (outcome?.status === 'authorized') {
        try {
          await this.#serialized(() => this.#ensureRoute(provider))
        } catch (error) {
          // The grant is stored; list() declares the route on its next call.
          this.#log(`${provider}: declaring the route failed: ${redact(error?.message ?? error)}`)
        }
        this.#finish(attempt, 'done')
      } else {
        this.#finishWithdrawn(attempt)
      }
    } catch (error) {
      if (attempt.timedOut || attempt.cancelRequested) {
        this.#finishWithdrawn(attempt)
      } else {
        this.#log(`${provider}: sign-in failed: ${redact(causes(error).map((e) => `${e?.name ?? ''}${e?.code ? `[${e.code}]` : ''}: ${e?.message ?? e}`).join(' <- '))}`)
        this.#finish(attempt, 'failed', describeFailure(error))
      }
    }
  }

  async #runPluginAttempt(attempt, providerId) {
    const signal = attempt.controller.signal
    const magpie = this.#ensureMagpie()
    try {
      let p = magpie.getProvider(providerId)
      if (!p) {
        const rows = await magpie.refreshProviders({ signal })
        p = rows.find((item) => item.id === providerId)
      }
      if (!p) {
        throw Object.assign(new Error(`no plugin provider for ${providerId}`), { code: 'NO_FLOW' })
      }
      const methods = Array.isArray(p.methods) ? p.methods : []
      if (methods.length === 0) {
        throw Object.assign(new Error(`plugin ${providerId} offered no login methods`), { code: 'NO_FLOW' })
      }

      this.#log(`${providerId}: plugin sign-in started (${attempt.id})`)
      let methodIdx = 0
      if (methods.length > 1) {
        const choice = await this.#askAttempt(attempt, {
          message: '选择登录方式',
          options: methods.map((m, i) => ({
            id: String(i),
            label: m.label || `登录方式 ${i + 1}`,
          })),
        })
        const idx = Number.parseInt(choice, 10)
        const byLabel = methods.findIndex((m) => m.label === choice)
        methodIdx = Number.isInteger(idx) && idx >= 0 && idx < methods.length ? idx : byLabel >= 0 ? byLabel : 0
      }

      const inputs = {}
      for (;;) {
        const promptRes = await magpie.call('prompt', { provider: providerId, method: methodIdx, inputs }, { signal })
        const pr = promptRes?.prompt
        if (!pr) break
        for (;;) {
          const options = Array.isArray(pr.options)
            ? pr.options.map((o) => ({
                id: String(o.value ?? ''),
                label: String(o.label ?? o.value ?? ''),
                ...(o.hint ? { hint: String(o.hint) } : {}),
              }))
            : undefined
          const answer = await this.#askAttempt(attempt, {
            message: pr.message || COPY.prompt,
            placeholder: pr.placeholder || undefined,
            options,
          })
          const valRes = await magpie.call(
            'validate',
            { provider: providerId, method: methodIdx, key: pr.key, value: answer },
            { signal },
          )
          if (valRes?.error) {
            attempt.error = String(valRes.error)
            continue
          }
          attempt.error = undefined
          inputs[pr.key] = answer
          break
        }
      }

      const method = methods[methodIdx]
      let targetProviderId = providerId
      if (method.type === 'api') {
        let key = ''
        if (!method.keyless) {
          key = await this.#askAttempt(attempt, {
            message: method.label || '请输入 API Key',
            placeholder: method.placeholder || 'API Key',
          })
        }
        attempt.set('starting', COPY.finishing)
        const res = await magpie.call(
          'apiKey',
          { provider: providerId, method: methodIdx, inputs, key },
          { signal },
        )
        if (!res?.ok) {
          this.#finish(attempt, 'failed', res?.error || ERRORS.generic)
          return
        }
        if (typeof res.provider === 'string' && res.provider) targetProviderId = res.provider
      } else {
        attempt.set('starting', COPY.starting)
        const authRes = await magpie.call(
          'authorize',
          { provider: providerId, method: methodIdx, inputs },
          { signal },
        )
        if (!authRes?.ok) {
          this.#finish(attempt, 'failed', authRes?.error || ERRORS.generic)
          return
        }
        let cbRes
        if (authRes.method === 'code') {
          attempt.url = authRes.url || undefined
          const code = await this.#askAttempt(attempt, {
            message: authRes.instructions || COPY.prompt,
            placeholder: '粘贴授权码或回调网址',
          })
          attempt.set('starting', COPY.finishing)
          cbRes = await magpie.call('callback', { session: authRes.session, code }, { signal })
        } else {
          const code = extractDeviceCode(authRes.instructions)
          attempt.url = authRes.url || undefined
          if (code !== undefined) {
            attempt.userCode = code
            attempt.set('device', authRes.instructions || COPY.device)
          } else {
            attempt.set('open', authRes.instructions || COPY.open)
          }
          cbRes = await magpie.call('callback', { session: authRes.session }, { signal })
        }
        if (!cbRes?.ok) {
          this.#finish(attempt, 'failed', cbRes?.error || ERRORS.generic)
          return
        }
        if (typeof cbRes.provider === 'string' && cbRes.provider) targetProviderId = cbRes.provider
      }

      const refreshed = await magpie.refreshProviders({ signal })
      const updated = refreshed.find((item) => item.id === targetProviderId) ?? refreshed.find((item) => item.id === providerId)
      if (updated?.signedIn) {
        try {
          await this.#serialized(() => this.#ensurePluginRoute(updated))
        } catch (error) {
          this.#log(`${updated.id}: declaring plugin route failed: ${redact(error?.message ?? error)}`)
        }
      }
      this.#finish(attempt, 'done')
    } catch (error) {
      if (attempt.timedOut || attempt.cancelRequested) {
        this.#finishWithdrawn(attempt)
      } else {
        this.#log(
          `${providerId}: plugin sign-in failed: ${redact(
            causes(error)
              .map((e) => `${e?.name ?? ''}${e?.code ? `[${e.code}]` : ''}: ${e?.message ?? e}`)
              .join(' <- '),
          )}`,
        )
        this.#finish(attempt, 'failed', describeFailure(error))
      }
    }
  }

  #askAttempt(attempt, { message, placeholder, options }) {
    return new Promise((resolve, reject) => {
      if (!attempt.live || attempt.controller.signal.aborted) {
        reject(new Error('the sign-in is over'))
        return
      }
      const pending = { resolve, reject }
      const withdraw = () => {
        if (attempt.pending !== pending) return
        attempt.pending = undefined
        attempt.placeholder = undefined
        attempt.options = undefined
        if (attempt.live && (attempt.phase === 'open' || attempt.phase === 'prompt')) {
          attempt.set('starting', COPY.finishing)
        }
        reject(new Error('the prompt was withdrawn'))
      }
      attempt.controller.signal.addEventListener('abort', withdraw, { once: true })
      attempt.pending = pending
      attempt.placeholder = typeof placeholder === 'string' && placeholder.length > 0 ? placeholder : undefined
      attempt.options = Array.isArray(options) && options.length > 0 ? options : undefined
      attempt.set('prompt', message || COPY.prompt)
    })
  }

  #finishWithdrawn(attempt) {
    if (attempt.timedOut) this.#finish(attempt, 'failed', ERRORS.timeout)
    else this.#finish(attempt, 'cancelled', ERRORS.cancelled)
  }

  /** A notice from pi-ai's login (via llm-pi-ai's relay): a page to open, a device code, or progress. */
  #onNotice(attempt, notice) {
    if (!attempt.live || !isObject(notice)) return
    const url = typeof notice.url === 'string' && notice.url.length > 0 ? notice.url : undefined
    const code = typeof notice.code === 'string' && notice.code.length > 0 ? notice.code : undefined
    if (url !== undefined && code !== undefined) {
      this.#log(`${attempt.provider}: device code for ${hostOf(url)}`)
      attempt.url = url
      attempt.userCode = code
      attempt.set('device', COPY.device)
      return
    }
    if (url !== undefined) {
      this.#log(`${attempt.provider}: authorize page at ${hostOf(url)}${attempt.callbackLikely ? '' : ' (paste only)'}`)
      attempt.url = url
      if (attempt.callbackLikely) attempt.set('open', COPY.open)
      else attempt.set('prompt', COPY.prompt)
      return
    }
    // Progress ("Exchanging authorization code…"): the browser part is over.
    if (attempt.pending === undefined && attempt.phase !== 'starting') attempt.set('starting', COPY.finishing)
  }

  /** A question from pi-ai's login. */
  #onPrompt(attempt, prompt) {
    if (isObject(prompt) && prompt.kind === 'select') {
      // pi-ai first asks which login to run. Browser login is the phone's best
      // path (one tap through Custom Tabs, the engine catches the localhost
      // redirect) and it keeps a paste fallback of its own.
      const options = Array.isArray(prompt.options) ? prompt.options : []
      const choice = options.find((option) => option?.id === 'browser') ?? options[0]
      if (choice === undefined) return Promise.reject(new Error('the login offered no method'))
      this.#log(`${attempt.provider}: login method "${choice.id}"`)
      return Promise.resolve(choice.id)
    }
    // text / secret: the authorization code or the redirect URL, pasted. In a
    // browser login this races the callback; pi-ai withdraws it (prompt.signal)
    // once the callback arrives.
    return new Promise((resolve, reject) => {
      if (!attempt.live || attempt.controller.signal.aborted) {
        reject(new Error('the sign-in is over'))
        return
      }
      const pending = { resolve, reject }
      const withdraw = () => {
        if (attempt.pending !== pending) return
        attempt.pending = undefined
        attempt.placeholder = undefined
        if (attempt.live && (attempt.phase === 'open' || attempt.phase === 'prompt')) attempt.set('starting', COPY.finishing)
        reject(new Error('the prompt was withdrawn'))
      }
      prompt?.signal?.addEventListener?.('abort', withdraw, { once: true })
      attempt.controller.signal.addEventListener('abort', withdraw, { once: true })
      attempt.pending = pending
      attempt.placeholder = typeof prompt?.placeholder === 'string' ? prompt.placeholder : undefined
      if (attempt.url !== undefined && attempt.callbackLikely) attempt.set('open', COPY.open)
      else attempt.set('prompt', COPY.prompt)
    })
  }

  #abort(attempt) {
    if (!attempt.controller.signal.aborted) attempt.controller.abort(new Error('sign-in withdrawn'))
  }

  #finish(attempt, phase, error) {
    if (!attempt.live) return
    clearTimeout(attempt.timer)
    attempt.finishedAt = this.#now()
    attempt.phase = phase
    attempt.message = undefined
    attempt.error = error
    attempt.url = undefined
    attempt.userCode = undefined
    attempt.placeholder = undefined
    attempt.options = undefined
    const pending = attempt.pending
    attempt.pending = undefined
    pending?.reject(new Error('the sign-in is over'))
    if (this.#liveByProvider.get(attempt.provider) === attempt) this.#liveByProvider.delete(attempt.provider)
    this.#log(`${attempt.provider}: ${phase} (${attempt.id})`)
  }

  #prune() {
    const now = this.#now()
    const finished = [...this.#attempts.values()].filter((a) => !a.live).sort((a, b) => a.finishedAt - b.finishedAt)
    for (const attempt of finished) {
      if (now - attempt.finishedAt > FINISHED_KEEP_MS || this.#attempts.size > MAX_KEPT_ATTEMPTS) this.#attempts.delete(attempt.id)
    }
  }

  // ── llm-pi-ai routes ───────────────────────────────────────────────────

  #serialized(task) {
    const run = this.#routeQueue.then(task, task)
    this.#routeQueue = run.catch(() => {})
    return run
  }

  #section() {
    const settings = this.#get('settings')
    if (settings === undefined) throw new Error('settings service is absent')
    const section = settings.describe().find((candidate) => candidate.ns === this.#settingsNs)
    if (section === undefined) throw new Error(`settings namespace "${this.#settingsNs}" is not configurable`)
    return { settings, section }
  }

  /** Declares `providers.<id>` (catalog route: only a display name) unless some route already exists. */
  async #ensureRoute(provider) {
    const { settings, section } = this.#section()
    if (isObject(section.value?.providers?.[provider])) return false
    await settings.mutate(this.#settingsNs, [
      { op: 'set', path: ['providers', provider], value: { displayName: PROVIDERS[provider].displayName } },
    ])
    this.#log(`${provider}: route declared`)
    return true
  }

  /**
   * Removes `providers.<id>` when it is the bridge's: in the user layer and
   * without `apiKeyEnv` (a route with a key reference is the user's API-key
   * route and keeps working without the grant).
   */
  async #removeRoute(provider) {
    const { settings, section } = this.#section()
    if (!isObject(section.value?.providers?.[provider])) return 'absent'
    const own = section.user?.providers?.[provider]
    if (!isObject(own)) return 'inherited'
    if (typeof own.apiKeyEnv === 'string' && own.apiKeyEnv.length > 0) return 'api-key'
    await settings.mutate(this.#settingsNs, [{ op: 'unset', path: ['providers', provider] }])
    this.#log(`${provider}: route removed`)
    return 'removed'
  }

  /** Declares or updates a Magpie plugin provider route in `llm-pi-ai`. */
  async #ensurePluginRoute(pluginProvider) {
    const magpie = this.#ensureMagpie()
    await magpie.ensureServer()
    const { settings, section } = this.#section()
    const routeId = toPiAiRouteId(pluginProvider.id)
    const existing = section.value?.providers?.[routeId]
    // Do not overwrite a user's custom route that uses a different API key env.
    if (isObject(existing) && existing.apiKeyEnv && existing.apiKeyEnv !== MAGPIE_PLUGIN_KEY_ENV) {
      return false
    }
    const existingOverrides = isObject(existing?.modelOverrides) ? existing.modelOverrides : undefined
    const protocol = toPiAiProtocol(pluginProvider.npm, pluginProvider.models)
    const nextValue = {
      displayName: pluginProvider.name || pluginProvider.id,
      api: protocol,
      baseURL: magpie.baseUrlFor(pluginProvider.id, protocol),
      apiKeyEnv: MAGPIE_PLUGIN_KEY_ENV,
      models: toPiAiModels(pluginProvider.models, existingOverrides),
    }
    if (existingOverrides && Object.keys(existingOverrides).length > 0) {
      nextValue.modelOverrides = existingOverrides
    }
    if (isObject(existing) && JSON.stringify(existing) === JSON.stringify(nextValue)) {
      return false
    }
    await settings.mutate(this.#settingsNs, [{ op: 'set', path: ['providers', routeId], value: nextValue }])
    this.#log(`${pluginProvider.id}: plugin route declared (${routeId})`)
    return true
  }

  /** Removes a Magpie plugin provider route when owned by `MAGPIE_PLUGIN_KEY_ENV`. */
  async #removePluginRoute(providerId) {
    const { settings, section } = this.#section()
    const routeId = toPiAiRouteId(providerId)
    const own = section.user?.providers?.[routeId] ?? section.value?.providers?.[routeId]
    if (!isObject(own)) return 'absent'
    if (own.apiKeyEnv !== MAGPIE_PLUGIN_KEY_ENV) return 'not-magpie'
    await settings.mutate(this.#settingsNs, [{ op: 'unset', path: ['providers', routeId] }])
    this.#log(`${providerId}: plugin route removed (${routeId})`)
    return 'removed'
  }

  /** Removes any leftover Magpie plugin routes whose provider is no longer signed in. */
  async #pruneStalePluginRoutes(signedInRouteIds) {
    const { settings, section } = this.#section()
    const userProviders = section.user?.providers
    if (!isObject(userProviders)) return
    const mutations = []
    for (const [routeId, cfg] of Object.entries(userProviders)) {
      if (isObject(cfg) && cfg.apiKeyEnv === MAGPIE_PLUGIN_KEY_ENV && !signedInRouteIds.has(routeId)) {
        mutations.push({ op: 'unset', path: ['providers', routeId] })
      }
    }
    if (mutations.length > 0) {
      await settings.mutate(this.#settingsNs, mutations)
    }
  }
}
