package io.github.ccch1mneyyy.dsh_app.phone

import java.io.File
import java.io.IOException

/**
 * Guest-side files for the Root CLI & Local Loopback ADB / `android-cli` bridge:
 * - `/opt/dsh-app/root/client.cjs`: Node.js client talking to [RootCliBridge] over an abstract
 *   unix socket (`\0dsh-app.root.<hex>`) or `127.0.0.1` loopback fallback.
 * - `/usr/local/bin/host-su`: Runs a command as real Android Root (`uid=0`) outside PRoot.
 * - `/usr/local/bin/dsh-adb-bootstrap`: Authorizes the container's ADB key via Root, locks port
 *   5555 to loopback via `iptables`, starts `adbd`, and connects `adb` to `127.0.0.1:5555`.
 * - `/usr/local/bin/dsh-android-cli-install`: Bootstraps local ADB and installs Google's official
 *   `android` CLI (`linux_arm64` / `linux_x86_64`) into `/usr/local/bin/android`.
 * - `/var/lib/dsh-app/root/bridge.json`: Per-launch socket name, loopback port, and 32-byte token (`0600`).
 */
object RootCliGuest {
    const val CLIENT_SCRIPT = "/opt/dsh-app/root/client.cjs"
    const val CONFIG_FILE = "/var/lib/dsh-app/root/bridge.json"
    const val HOST_SU_BIN = "/usr/local/bin/host-su"
    const val ADB_BOOTSTRAP_BIN = "/usr/local/bin/dsh-adb-bootstrap"
    const val ANDROID_CLI_INSTALL_BIN = "/usr/local/bin/dsh-android-cli-install"

    val CLIENT_CJS = """
        // dsh-app: root & local adb bridge client. Written by RootCliGuest at engine start.
        'use strict';
        const fs = require('node:fs');
        const net = require('node:net');

        function resolvePath(guestPath) {
          if (fs.existsSync(guestPath)) return guestPath;
          const prefix = process.env.DSH_GO_DIRECT_ROOTFS || process.env.DSH_GO_RUNTIME_ROOT || '';
          return prefix ? prefix + guestPath : guestPath;
        }

        let cfg;
        try {
          cfg = JSON.parse(fs.readFileSync(resolvePath('$CONFIG_FILE'), 'utf8'));
        } catch (e) {
          process.stderr.write('host-su: root bridge is not active (' + e.message + ')\n');
          process.exit(126);
        }

        function parseArgs(argv) {
          let timeoutMs = 60000;
          let bootstrapKeyPath = null;
          let port = 5555;
          const rest = [];
          for (let i = 0; i < argv.length; i++) {
            const a = argv[i];
            if (a === '--bootstrap-adb' && i + 1 < argv.length) {
              bootstrapKeyPath = argv[++i];
            } else if (a === '--port' && i + 1 < argv.length) {
              port = Number(argv[++i]) || 5555;
            } else if (a === '--timeout' && i + 1 < argv.length) {
              timeoutMs = Number(argv[++i]) || 60000;
            } else if (a === '--') {
              rest.push(...argv.slice(i + 1));
              break;
            } else if (a === '-c' && i + 1 < argv.length) {
              rest.push(...argv.slice(i + 1));
              break;
            } else if ((a === 'root' || a === '-') && rest.length === 0 && i + 1 < argv.length) {
              continue;
            } else {
              rest.push(a);
            }
          }
          if (bootstrapKeyPath) {
            const pubKey = fs.readFileSync(bootstrapKeyPath, 'utf8').trim();
            return { token: cfg.token, op: 'bootstrap_adb', pubKey, port };
          }
          let cmd = rest.join(' ').trim();
          if (!cmd && !process.stdin.isTTY) {
            try {
              cmd = fs.readFileSync(0, 'utf8').trim();
            } catch (_) {}
          }
          if (!cmd) {
            process.stderr.write('Usage: host-su [-c] "<command>" | host-su --timeout <ms> -c "<command>"\n');
            process.exit(2);
          }
          return { token: cfg.token, op: 'exec', cmd, timeoutMs };
        }

        const payload = JSON.stringify(parseArgs(process.argv.slice(2))) + '\n';

        function connectAndRun(useTcpFallback) {
          const canUnix = Boolean(cfg.socket) && !useTcpFallback;
          const canTcp = Number.isInteger(cfg.tcpPort) && cfg.tcpPort > 0;
          if (!canUnix && !canTcp) {
            process.stderr.write('host-su: no bridge endpoint configured\n');
            process.exit(126);
          }
          const sock = canUnix
            ? net.connect({ path: '\0' + cfg.socket })
            : net.connect({ host: '127.0.0.1', port: cfg.tcpPort });
          let buffer = '';
          let settled = false;

          sock.on('connect', () => {
            sock.write(payload);
          });
          sock.on('data', (chunk) => {
            buffer += chunk.toString('utf8');
            const nl = buffer.indexOf('\n');
            if (nl >= 0 && !settled) {
              settled = true;
              sock.destroy();
              handleResponse(buffer.slice(0, nl));
            }
          });
          sock.on('error', (err) => {
            if (!settled && canUnix && canTcp) {
              settled = true;
              connectAndRun(true);
              return;
            }
            if (!settled) {
              settled = true;
              process.stderr.write('host-su: bridge connection failed (' + err.message + ')\n');
              process.exit(126);
            }
          });
          sock.on('close', () => {
            if (!settled) {
              if (buffer.trim()) {
                settled = true;
                handleResponse(buffer.trim());
              } else if (canUnix && canTcp) {
                settled = true;
                connectAndRun(true);
              } else {
                settled = true;
                process.stderr.write('host-su: bridge closed before replying\n');
                process.exit(126);
              }
            }
          });
        }

        function handleResponse(line) {
          let res;
          try {
            res = JSON.parse(line);
          } catch (e) {
            process.stderr.write('host-su: invalid response from bridge\n');
            process.exit(126);
          }
          if (res.stdout) process.stdout.write(String(res.stdout));
          if (res.stderr) process.stderr.write(String(res.stderr));
          const code = typeof res.exitCode === 'number' ? res.exitCode : (res.ok ? 0 : 1);
          process.exit(code);
        }

        connectAndRun(false);
    """.trimIndent() + "\n"

    val HOST_SU_SH = """
        #!/bin/sh
        if [ -x /opt/node/bin/node ]; then
          exec /opt/node/bin/node $CLIENT_SCRIPT "${'$'}@"
        elif [ -n "${'$'}{DSH_GO_RUNTIME_ROOT:-}" ] && [ -x "${'$'}{DSH_GO_RUNTIME_ROOT}/opt/dsh-app/direct/bin/node" ]; then
          exec "${'$'}{DSH_GO_RUNTIME_ROOT}/opt/dsh-app/direct/bin/node" "${'$'}{DSH_GO_RUNTIME_ROOT}$CLIENT_SCRIPT" "${'$'}@"
        else
          exec node $CLIENT_SCRIPT "${'$'}@"
        fi
    """.trimIndent() + "\n"

    val ADB_BOOTSTRAP_SH = """
        #!/bin/sh
        set -eu
        PORT="${'$'}{DSH_ADB_PORT:-5555}"
        SERIAL="127.0.0.1:${'$'}{PORT}"

        if ! command -v adb >/dev/null 2>&1; then
          echo "[dsh-adb-bootstrap] Installing adb..." >&2
          export DEBIAN_FRONTEND=noninteractive
          apt-get update -y && apt-get install -y adb
        fi

        mkdir -p /root/.android
        chmod 0700 /root/.android
        if [ ! -f /root/.android/adbkey ] || [ ! -f /root/.android/adbkey.pub ]; then
          rm -f /root/.android/adbkey /root/.android/adbkey.pub
          adb keygen /root/.android/adbkey
        fi

        if [ -x /opt/node/bin/node ]; then
          NODE_BIN=/opt/node/bin/node
        else
          NODE_BIN=node
        fi

        "${'$'}NODE_BIN" $CLIENT_SCRIPT --bootstrap-adb /root/.android/adbkey.pub --port "${'$'}PORT"

        adb start-server >/dev/null 2>&1 || true
        i=0
        while [ "${'$'}i" -lt 10 ]; do
          out="${'$'}(adb connect "${'$'}SERIAL" 2>&1 || true)"
          if adb -s "${'$'}SERIAL" get-state >/dev/null 2>&1; then
            echo "[dsh-adb-bootstrap] Ready: ${'$'}SERIAL"
            exit 0
          fi
          i=${'$'}((i + 1))
          sleep 1
        done
        echo "[dsh-adb-bootstrap] Failed to connect to ${'$'}SERIAL: ${'$'}{out:-unknown}" >&2
        exit 1
    """.trimIndent() + "\n"

    val ANDROID_CLI_INSTALL_SH = """
        #!/bin/sh
        set -eu

        $ADB_BOOTSTRAP_BIN

        if ! command -v curl >/dev/null 2>&1; then
          echo "[dsh-android-cli-install] Installing curl and ca-certificates..." >&2
          export DEBIAN_FRONTEND=noninteractive
          apt-get update -y && apt-get install -y curl ca-certificates
        fi

        ARCH="${'$'}(uname -m)"
        case "${'$'}ARCH" in
          aarch64|arm64) PLATFORM="linux_arm64" ;;
          x86_64|amd64) PLATFORM="linux_x86_64" ;;
          *)
            echo "[dsh-android-cli-install] Unsupported architecture: ${'$'}ARCH" >&2
            exit 1
            ;;
        esac

        if [ ! -x /root/.local/bin/android ] && ! command -v android >/dev/null 2>&1; then
          echo "[dsh-android-cli-install] Installing Google Android CLI (${'$'}PLATFORM)..." >&2
          curl -fsSL "https://dl.google.com/android/cli/latest/${'$'}{PLATFORM}/install.sh" | bash
        fi

        if [ -x /root/.local/bin/android ]; then
          ln -sf /root/.local/bin/android /usr/local/bin/android
        fi

        mkdir -p /root/Android/Sdk/platform-tools
        if command -v adb >/dev/null 2>&1; then
          ln -sf "${'$'}(command -v adb)" /root/Android/Sdk/platform-tools/adb
        fi

        android --version
    """.trimIndent() + "\n"

    // l10n:keep-begin agent prompt
    val AGENTS_SECTION = """
        |
        |## 本机 Root、回环 ADB 与 Android CLI
        |
        |- 容器运行在 PRoot / glibc 环境，直接调 `/system/bin/su` 会受路径转换与环境变量干扰；若手机已 Root（Magisk / KernelSU / APatch），用预置的 `host-su -c "<命令>"` 在宿主 Android 环境以真实 Root (`uid=0`) 执行命令（首次调用需用户在 Root 管理器中授权 DSH Go）。
        |- 需要使用 `adb` 时先运行 `dsh-adb-bootstrap`：它通过 Root 自动将容器公钥写入 `/data/misc/adb/adb_keys`、配置仅允许 `127.0.0.1:5555` 回环访问的防火墙规则并启动本机 `adbd`，无需电脑或无线调试配对即可执行 `adb shell`、`adb install`、`adb logcat` 等。
        |- 需要使用 Google 官方 `android` CLI（`android-cli`）时先运行 `dsh-android-cli-install`：它会自动完成本机回环 ADB 连通并安装 `linux_arm64` 版 `android` 到 `/usr/local/bin/android`，之后可直接运行 `android layout`（查看布局树与真实坐标）、`android screen capture --annotate`（带编号截图）、`android screen resolve`、`android docs` 等命令。
        |""".trimMargin()
    // l10n:keep-end

    fun writeFiles(rootfs: File) {
        writeAtomic(File(rootfs, CLIENT_SCRIPT.removePrefix("/")), CLIENT_CJS, executable = false)
        writeAtomic(File(rootfs, HOST_SU_BIN.removePrefix("/")), HOST_SU_SH, executable = true)
        writeAtomic(File(rootfs, ADB_BOOTSTRAP_BIN.removePrefix("/")), ADB_BOOTSTRAP_SH, executable = true)
        writeAtomic(File(rootfs, ANDROID_CLI_INSTALL_BIN.removePrefix("/")), ANDROID_CLI_INSTALL_SH, executable = true)
    }

    fun writeConfig(rootfs: File, ep: RootCliBridge.Endpoint) {
        val f = File(rootfs, CONFIG_FILE.removePrefix("/"))
        val dir = f.parentFile ?: throw IOException("no parent for ${f.path}")
        if (!dir.isDirectory && !dir.mkdirs()) throw IOException("could not create ${dir.path}")
        val tmp = File(dir, ".${f.name}.dsh-tmp")
        val map = linkedMapOf<String, Any?>("socket" to ep.socketName, "token" to ep.token)
        if (ep.tcpPort != null) map["tcpPort"] = ep.tcpPort
        try {
            tmp.writeText(Json.write(map) + "\n")
            tmp.setReadable(false, false)
            tmp.setWritable(false, false)
            tmp.setReadable(true, true)
            tmp.setWritable(true, true)
            if (!tmp.renameTo(f)) throw IOException("could not replace ${f.path}")
        } finally {
            if (tmp.exists()) tmp.delete()
        }
    }

    fun clearConfig(rootfs: File) {
        runCatching { File(rootfs, CONFIG_FILE.removePrefix("/")).delete() }
    }

    private fun writeAtomic(target: File, content: String, executable: Boolean) {
        val dir = target.parentFile ?: throw IOException("no parent for ${target.path}")
        if (!dir.isDirectory && !dir.mkdirs()) throw IOException("could not create ${dir.path}")
        if (target.isFile && target.readText() == content && (!executable || target.canExecute())) return
        val tmp = File(dir, ".${target.name}.dsh-tmp-${System.nanoTime()}")
        try {
            tmp.writeText(content)
            tmp.setReadable(true, false)
            if (executable) tmp.setExecutable(true, false)
            if (!tmp.renameTo(target)) throw IOException("could not replace ${target.path}")
        } finally {
            if (tmp.exists()) tmp.delete()
        }
    }
}
