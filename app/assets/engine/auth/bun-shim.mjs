// SPDX-License-Identifier: MIT
//
// Thin Node.js 22+ compatibility shim so Magpie's unmodified `host.js` and
// `pi.js` (written for Bun) run directly on Node.js inside DSH's runtime.
//
// Loaded via:
//   node --import ./bun-shim.mjs --experimental-strip-types ./host.js

import childProcess from 'node:child_process'
import fs from 'node:fs'
import { createRequire, register } from 'node:module'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { inspect } from 'node:util'

// ── 1. ESM loader hook for host.js/pi.js and TypeScript/extensionless plugins ─

const LOADER_CODE = `
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const EXTENSIONS = ['.ts', '.tsx', '.mjs', '.js', '.cjs', '.json']
const INDEX_FILES = ['index.ts', 'index.tsx', 'index.mjs', 'index.js', 'index.cjs']

function tryFile(p) {
  try {
    const st = fs.statSync(p)
    if (st.isFile()) return p
    if (st.isDirectory()) {
      for (const idx of INDEX_FILES) {
        const candidate = path.join(p, idx)
        if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate
      }
    }
  } catch {}
  return null
}

export async function resolve(specifier, context, nextResolve) {
  try {
    return await nextResolve(specifier, context)
  } catch (err) {
    if (
      context.parentURL &&
      (specifier.startsWith('./') || specifier.startsWith('../') || specifier.startsWith('/') || specifier.startsWith('file://'))
    ) {
      const parentDir = path.dirname(fileURLToPath(context.parentURL))
      const base = specifier.startsWith('file://') ? fileURLToPath(specifier) : path.resolve(parentDir, specifier)
      // Direct or directory index match
      const direct = tryFile(base)
      if (direct) return { url: pathToFileURL(direct).href, shortCircuit: true }
      // .js -> .ts / .tsx mapping (common in TypeScript ESM packages)
      if (/\\.[cm]?js$/.test(base)) {
        const stem = base.replace(/\\.[cm]?js$/, '')
        for (const ext of ['.ts', '.tsx', '.mts', '.cts']) {
          const hit = tryFile(stem + ext)
          if (hit) return { url: pathToFileURL(hit).href, shortCircuit: true }
        }
      }
      // Extensionless import
      for (const ext of EXTENSIONS) {
        const hit = tryFile(base + ext)
        if (hit) return { url: pathToFileURL(hit).href, shortCircuit: true }
      }
    }
    throw err
  }
}

export async function load(url, context, nextLoad) {
  if (url.endsWith('/host.js') || url.endsWith('/pi.js')) {
    const source = fs.readFileSync(fileURLToPath(url), 'utf8')
    return { format: 'module', shortCircuit: true, source }
  }
  return nextLoad(url, context)
}
`

register(`data:text/javascript;base64,${Buffer.from(LOADER_CODE, 'utf8').toString('base64')}`, import.meta.url)

// ── 2. Fetch compatibility (Node undici duplex + Bun proxy option strip) ────

const nativeFetch = globalThis.fetch
if (typeof nativeFetch === 'function') {
  globalThis.fetch = function shimmedFetch(input, init) {
    if (init && typeof init === 'object') {
      const next = { ...init }
      if ('proxy' in next) delete next.proxy
      if (next.body != null && typeof next.body === 'object' && !(next.body instanceof Uint8Array) && !(next.body instanceof ArrayBuffer) && !ArrayBuffer.isView(next.body) && typeof next.body.getReader === 'function' && !next.duplex) {
        next.duplex = 'half'
      }
      return nativeFetch.call(this, input, next)
    }
    return nativeFetch.call(this, input, init)
  }
}

// ── 3. Child process stdio guard (matches host.js's Bun.spawn guard) ────────
// In Bun, node:child_process routes through Bun.spawn. In Node.js, plugins
// calling child_process.spawn directly with stdio: 'inherit' could write to
// fd 1 (host.js's JSON-RPC stdout) or read fd 0 (host.js's stdin).

const origSpawn = childProcess.spawn
const origSpawnSync = childProcess.spawnSync

function guardNodeStdio(options) {
  if (!options || typeof options !== 'object') return options
  const o = { ...options }
  const isOwnIn = (v) => v === 'inherit' || v === 0 || v === process.stdin
  const isOwnOut = (v) => v === 'inherit' || v === 1 || v === process.stdout
  if (typeof o.stdio === 'string') {
    if (o.stdio === 'inherit') o.stdio = ['ignore', 2, 2]
  } else if (Array.isArray(o.stdio)) {
    o.stdio = [...o.stdio]
    if (isOwnIn(o.stdio[0])) o.stdio[0] = 'ignore'
    if (isOwnOut(o.stdio[1])) o.stdio[1] = 2
  }
  return o
}

childProcess.spawn = function guardedSpawn(command, args, options) {
  if (Array.isArray(args)) {
    return origSpawn.call(this, command, args, guardNodeStdio(options))
  }
  return origSpawn.call(this, command, guardNodeStdio(args))
}

childProcess.spawnSync = function guardedSpawnSync(command, args, options) {
  if (Array.isArray(args)) {
    return origSpawnSync.call(this, command, args, guardNodeStdio(options))
  }
  return origSpawnSync.call(this, command, guardNodeStdio(args))
}

// ── 4. globalThis.Bun shim ──────────────────────────────────────────────────

function normalizeBunSpawnArgs(a, b) {
  const cmd = Array.isArray(a) ? a : Array.isArray(a?.cmd) ? a.cmd : [String(a)]
  const opts = (Array.isArray(a) ? b : a) ?? {}
  const stdio = [
    opts.stdin === 'ignore' || opts.stdin == null ? 'ignore' : opts.stdin,
    opts.stdout === 2 || opts.stdout === process.stderr ? 2 : 'pipe',
    opts.stderr === 'ignore' ? 'ignore' : 'pipe',
  ]
  return { cmd, opts, stdio }
}

function bunSpawn(a, b) {
  const { cmd, opts, stdio } = normalizeBunSpawnArgs(a, b)
  const child = origSpawn(cmd[0], cmd.slice(1), {
    cwd: opts.cwd,
    env: opts.env ?? process.env,
    stdio,
  })
  const exited = new Promise((resolve) => {
    child.on('close', (code) => resolve(code ?? 1))
    child.on('error', () => resolve(1))
  })
  return {
    pid: child.pid,
    stdout: child.stdout,
    stderr: child.stderr,
    exited,
    kill: (sig) => child.kill(sig),
    unref: () => child.unref(),
  }
}

function bunSpawnSync(a, b) {
  const { cmd, opts, stdio } = normalizeBunSpawnArgs(a, b)
  const res = origSpawnSync(cmd[0], cmd.slice(1), {
    cwd: opts.cwd,
    env: opts.env ?? process.env,
    stdio,
  })
  return {
    exitCode: res.status ?? 1,
    stdout: res.stdout ?? Buffer.alloc(0),
    stderr: res.stderr ?? Buffer.alloc(0),
    success: res.status === 0,
  }
}

function createBunShell() {
  function runShell(strings, ...values) {
    let command = ''
    for (let i = 0; i < strings.length; i++) {
      command += strings[i]
      if (i < values.length) {
        const v = values[i]
        command += Array.isArray(v) ? v.map(String).join(' ') : String(v ?? '')
      }
    }
    let cwd = process.cwd()
    let env = process.env
    let noThrow = false

    const execute = () =>
      new Promise((resolve, reject) => {
        const child = origSpawn('/bin/sh', ['-c', command], {
          cwd,
          env,
          stdio: ['ignore', 'pipe', 'pipe'],
        })
        const out = []
        const err = []
        child.stdout?.on('data', (c) => out.push(c))
        child.stderr?.on('data', (c) => err.push(c))
        child.on('error', (e) => {
          if (noThrow) {
            const empty = Buffer.alloc(0)
            resolve({ exitCode: 1, stdout: empty, stderr: Buffer.from(String(e)), text: () => '', json: () => ({}), lines: () => [] })
          } else {
            reject(e)
          }
        })
        child.on('close', (code) => {
          const stdout = Buffer.concat(out)
          const stderr = Buffer.concat(err)
          const exitCode = code ?? 1
          const result = {
            exitCode,
            stdout,
            stderr,
            text: () => stdout.toString('utf8'),
            json: () => JSON.parse(stdout.toString('utf8')),
            lines: () => stdout.toString('utf8').split(/\r?\n/),
          }
          if (exitCode !== 0 && !noThrow) {
            const error = new Error(`Command failed with exit code ${exitCode}: ${stderr.toString('utf8').trim() || command}`)
            Object.assign(error, result)
            reject(error)
          } else {
            resolve(result)
          }
        })
      })

    let promise
    const getPromise = () => (promise ??= execute())
    const builder = {
      quiet() {
        return builder
      },
      nothrow() {
        noThrow = true
        return builder
      },
      throws(enable = true) {
        noThrow = !enable
        return builder
      },
      cwd(dir) {
        cwd = dir
        return builder
      },
      env(nextEnv) {
        env = { ...process.env, ...nextEnv }
        return builder
      },
      async text() {
        return (await getPromise()).text()
      },
      async json() {
        return (await getPromise()).json()
      },
      async lines() {
        return (await getPromise()).lines()
      },
      async blob() {
        const res = await getPromise()
        return new Blob([res.stdout])
      },
      then(onFulfilled, onRejected) {
        return getPromise().then(onFulfilled, onRejected)
      },
      catch(onRejected) {
        return getPromise().catch(onRejected)
      },
      finally(onFinally) {
        return getPromise().finally(onFinally)
      },
    }
    return builder
  }
  return runShell
}

function resolveSync(specifier, parentDir) {
  const candidates = [
    parentDir ? (parentDir.startsWith('file://') ? fileURLToPath(parentDir) : parentDir) : process.cwd(),
    process.env.DSH_INSTALL_DIR,
    '/opt/dsh/node_modules/@deepseek-ai/dsh',
  ].filter(Boolean)
  let lastErr
  for (const dir of candidates) {
    try {
      const anchor = fs.existsSync(path.join(dir, 'package.json')) ? path.join(dir, 'package.json') : path.join(dir, '__noop__.js')
      return createRequire(anchor).resolve(specifier)
    } catch (err) {
      lastErr = err
    }
  }
  throw lastErr ?? new Error(`Cannot resolve ${specifier}`)
}

if (!globalThis.Bun) {
  globalThis.Bun = {
    version: process.versions.node,
    inspect: (value, options) => inspect(value, options),
    spawn: bunSpawn,
    spawnSync: bunSpawnSync,
    resolveSync,
    $: createBunShell(),
  }
}
