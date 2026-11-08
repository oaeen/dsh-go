package io.github.ccch1mneyyy.dsh_app.phone

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Process
import io.github.ccch1mneyyy.dsh_app.phone.background.RootProcess
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Authenticated local bridge that lets guest CLI tools (`/usr/local/bin/host-su`,
 * `/usr/local/bin/dsh-adb-bootstrap`) run commands in the host Android environment outside PRoot via
 * `su -c`, and bootstrap local loopback `adbd` (`127.0.0.1:5555`) for `adb` and `android-cli`.
 *
 * Security model:
 * - Abstract unix socket checks `SO_PEERCRED` (`peerCredentials.uid == Process.myUid()`).
 * - Both the abstract socket and the `127.0.0.1` loopback fallback require a per-launch 32-byte
 *   random token stored in `/var/lib/dsh-app/root/bridge.json` (`0600`), verified in constant time.
 * - Never started in safe mode; stopped and token cleared when the engine stops.
 */
class RootCliBridge(
    private val runner: CommandRunner = HostSuRunner,
    private val log: (String) -> Unit = {},
) {
    data class Endpoint(val socketName: String, val token: String, val tcpPort: Int? = null)

    data class ExecResult(
        val exitCode: Int,
        val stdout: String,
        val stderr: String,
        val timedOut: Boolean = false,
        val truncated: Boolean = false,
    )

    fun interface CommandRunner {
        fun run(cmd: String, timeoutMs: Long): ExecResult
    }

    private val running = AtomicBoolean(false)
    private val connections = AtomicInteger(0)
    @Volatile private var unixServer: LocalServerSocket? = null
    @Volatile private var tcpServer: ServerSocket? = null
    @Volatile var endpoint: Endpoint? = null
        private set

    val listening: Boolean get() = running.get()
    val authenticatedConnections: Int get() = connections.get()

    @Synchronized
    fun start(withTcp: Boolean = true, bindAbstractSocket: Boolean = true): Endpoint {
        stop()
        val name = "dsh-app.root." + hex(8)
        val token = hex(32)
        val unix = if (bindAbstractSocket) runCatching { LocalServerSocket(name) }.getOrNull() else null
        val tcp = if (withTcp || unix == null) {
            ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        } else null
        unixServer = unix
        tcpServer = tcp
        val ep = Endpoint(if (unix != null) name else "", token, tcp?.localPort)
        endpoint = ep
        running.set(true)
        if (unix != null) {
            Thread({ acceptUnixLoop(unix, token) }, "dsh-root-unix").apply { isDaemon = true; start() }
        }
        if (tcp != null) {
            Thread({ acceptTcpLoop(tcp, token) }, "dsh-root-tcp").apply { isDaemon = true; start() }
        }
        log("[dsh-app] root cli bridge listening on ${if (unix != null) "@$name" else "tcp-only"}${tcp?.let { " and 127.0.0.1:${it.localPort}" } ?: ""}")
        return ep
    }

    @Synchronized
    fun stop() {
        running.set(false)
        connections.set(0)
        endpoint = null
        runCatching { unixServer?.close() }
        runCatching { tcpServer?.close() }
        unixServer = null
        tcpServer = null
    }

    private fun acceptUnixLoop(server: LocalServerSocket, token: String) {
        val myUid = runCatching { Process.myUid() }.getOrDefault(-1)
        val pool = Executors.newCachedThreadPool { r -> Thread(r, "dsh-root-conn").apply { isDaemon = true } }
        try {
            while (running.get()) {
                val sock: LocalSocket = try {
                    server.accept()
                } catch (_: Exception) {
                    break
                }
                pool.execute {
                    sock.use {
                        val peerUid = runCatching { sock.peerCredentials.uid }.getOrDefault(-2)
                        if (peerUid != myUid) {
                            log("[dsh-app] root cli bridge rejected peer uid $peerUid (expected $myUid)")
                            return@use
                        }
                        serve(sock.inputStream, sock.outputStream, sock, token)
                    }
                }
            }
        } finally {
            pool.shutdownNow()
        }
    }

    private fun acceptTcpLoop(server: ServerSocket, token: String) {
        val pool = Executors.newCachedThreadPool { r -> Thread(r, "dsh-root-tcp-conn").apply { isDaemon = true } }
        try {
            while (running.get()) {
                val sock: Socket = try {
                    server.accept()
                } catch (_: Exception) {
                    break
                }
                pool.execute {
                    sock.use {
                        if (sock.inetAddress?.isLoopbackAddress != true) return@use
                        serve(sock.getInputStream(), sock.getOutputStream(), sock, token)
                    }
                }
            }
        } finally {
            pool.shutdownNow()
        }
    }

    private fun serve(input: InputStream, output: OutputStream, closeable: Closeable, token: String) {
        val stopWatcher = Thread({
            while (running.get() && !Thread.currentThread().isInterrupted) {
                try {
                    Thread.sleep(250)
                } catch (_: InterruptedException) {
                    return@Thread
                }
            }
            if (!running.get()) runCatching { closeable.close() }
        }, "dsh-root-watch").apply { isDaemon = true; start() }
        try {
            val line = readLineBounded(input, MAX_LINE_BYTES) ?: return
            val response = handleRequest(line, token)
            if (response["error"] != "unauthorized") {
                connections.incrementAndGet()
            }
            val bytes = (Json.write(response) + "\n").toByteArray(Charsets.UTF_8)
            output.write(bytes)
            output.flush()
        } catch (_: Exception) {
        } finally {
            stopWatcher.interrupt()
        }
    }

    internal fun handleRequest(rawLine: String, expectedToken: String): Map<String, Any?> {
        val msg = try {
            Json.parse(rawLine) as? Map<*, *>
        } catch (_: Exception) {
            null
        } ?: return errorMap(2, "bad_json", "RootCliBridge: malformed JSON request\n")

        val gotToken = msg["token"] as? String ?: ""
        if (!constantTimeEquals(gotToken, expectedToken)) {
            log("[dsh-app] root cli bridge rejected connection: bad token")
            return errorMap(126, "unauthorized", "RootCliBridge: unauthorized\n")
        }

        return when (msg["op"] as? String) {
            "exec" -> {
                val cmd = (msg["cmd"] as? String)?.takeIf { it.isNotBlank() && '\u0000' !in it }
                    ?: return errorMap(2, "invalid_command", "RootCliBridge: command must be non-empty\n")
                val timeoutMs = ((msg["timeoutMs"] as? Number)?.toLong() ?: DEFAULT_TIMEOUT_MS)
                    .coerceIn(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
                toResponseMap(runner.run(cmd, timeoutMs))
            }
            "bootstrap_adb" -> {
                val pubKey = (msg["pubKey"] as? String)?.trim() ?: ""
                val port = (msg["port"] as? Number)?.toInt() ?: DEFAULT_ADB_PORT
                val script = try {
                    bootstrapAdbScript(pubKey, port)
                } catch (e: IllegalArgumentException) {
                    return errorMap(2, "invalid_adb_params", "RootCliBridge: ${e.message}\n")
                }
                toResponseMap(runner.run(script, ADB_BOOTSTRAP_TIMEOUT_MS))
            }
            else -> errorMap(2, "unsupported_op", "RootCliBridge: unsupported operation\n")
        }
    }

    private fun toResponseMap(res: ExecResult): Map<String, Any?> = linkedMapOf(
        "ok" to (res.exitCode == 0 && !res.timedOut),
        "exitCode" to res.exitCode,
        "stdout" to res.stdout,
        "stderr" to res.stderr,
        "timedOut" to res.timedOut,
        "truncated" to res.truncated,
    )

    private fun errorMap(exitCode: Int, error: String, stderr: String): Map<String, Any?> = linkedMapOf(
        "ok" to false,
        "exitCode" to exitCode,
        "error" to error,
        "stdout" to "",
        "stderr" to stderr,
        "timedOut" to false,
        "truncated" to false,
    )

    object HostSuRunner : CommandRunner {
        override fun run(cmd: String, timeoutMs: Long): ExecResult {
            val proc = try {
                RootProcess.spawnHostSu(cmd, HOST_PATH)
            } catch (e: Exception) {
                return ExecResult(
                    exitCode = 127,
                    stdout = "",
                    stderr = "host-su: failed to start su (${e.message ?: e.javaClass.simpleName})\n",
                )
            }
            runCatching { proc.outputStream.close() }
            val outBuf = BoundedCollector(MAX_OUTPUT_BYTES)
            val errBuf = BoundedCollector(MAX_OUTPUT_BYTES)
            val outThread = Thread({ outBuf.drain(proc.inputStream) }, "dsh-root-stdout").apply { isDaemon = true; start() }
            val errThread = Thread({ errBuf.drain(proc.errorStream) }, "dsh-root-stderr").apply { isDaemon = true; start() }
            val finished = try {
                proc.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                proc.destroyForcibly()
                false
            }
            if (!finished) {
                proc.destroyForcibly()
                runCatching { proc.waitFor(1, TimeUnit.SECONDS) }
            }
            runCatching { outThread.join(1_000) }
            runCatching { errThread.join(1_000) }
            val truncated = outBuf.truncated || errBuf.truncated
            return if (!finished) {
                ExecResult(
                    exitCode = 124,
                    stdout = outBuf.text(),
                    stderr = errBuf.text() + "\nhost-su: command timed out after ${timeoutMs}ms\n",
                    timedOut = true,
                    truncated = truncated,
                )
            } else {
                ExecResult(
                    exitCode = proc.exitValue(),
                    stdout = outBuf.text(),
                    stderr = errBuf.text(),
                    timedOut = false,
                    truncated = truncated,
                )
            }
        }
    }

    private class BoundedCollector(private val limit: Int) {
        private val out = ByteArrayOutputStream(minOf(limit, 4096))
        @Volatile var truncated = false
            private set

        fun drain(stream: InputStream) {
            val buf = ByteArray(4096)
            try {
                while (true) {
                    val n = stream.read(buf)
                    if (n < 0) break
                    val remain = limit - out.size()
                    if (remain > 0) {
                        out.write(buf, 0, minOf(n, remain))
                    }
                    if (n > remain) truncated = true
                }
            } catch (_: Exception) {
            }
        }

        fun text(): String = out.toString(Charsets.UTF_8.name())
    }

    companion object {
        const val DEFAULT_TIMEOUT_MS = 60_000L
        const val MIN_TIMEOUT_MS = 1_000L
        const val MAX_TIMEOUT_MS = 600_000L
        const val ADB_BOOTSTRAP_TIMEOUT_MS = 30_000L
        const val DEFAULT_ADB_PORT = 5555
        const val MAX_LINE_BYTES = 256 * 1024
        const val MAX_OUTPUT_BYTES = 512 * 1024

        const val HOST_PATH =
            "/product/bin:/apex/com.android.runtime/bin:/apex/com.android.art/bin:/system_ext/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin"

        private val BASE64_KEY = Regex("^[A-Za-z0-9+/=]{64,4096}$")
        private val rng = SecureRandom()

        private fun hex(bytes: Int): String {
            val b = ByteArray(bytes).also(rng::nextBytes)
            val chars = "0123456789abcdef"
            return CharArray(bytes * 2) { i ->
                val v = b[i shr 1].toInt() and 0xff
                chars[if (i and 1 == 0) v ushr 4 else v and 0x0f]
            }.concatToString()
        }

        internal fun constantTimeEquals(a: String, b: String): Boolean =
            MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))

        internal fun quoteShell(value: String): String {
            require('\u0000' !in value && '\n' !in value && '\r' !in value) { "invalid shell argument" }
            return "'" + value.replace("'", "'\\''") + "'"
        }

        /** Validates an `adbkey.pub` line and returns `(fullLine, keyBody)`. */
        internal fun validateAdbPublicKey(rawKey: String): Pair<String, String> {
            val line = rawKey.trim()
            require(line.length in 64..8192) { "invalid adb public key length" }
            require(line.all { it in '\u0020'..'\u007e' }) { "adb public key must be printable single-line ASCII" }
            val body = line.split(Regex("\\s+")).firstOrNull() ?: ""
            require(BASE64_KEY.matches(body)) { "invalid adb public key base64 body" }
            return line to body
        }

        /**
         * Builds the idempotent host Root script that authorizes [pubKey] in `/data/misc/adb/adb_keys`,
         * restricts TCP [port] to loopback (`127.0.0.1` / `::1`) via `iptables`/`ip6tables`, and starts
         * `adbd` listening on TCP [port].
         */
        fun bootstrapAdbScript(pubKey: String, port: Int = DEFAULT_ADB_PORT): String {
            require(port in 1024..65535) { "adb port out of range: $port" }
            val (keyLine, keyBody) = validateAdbPublicKey(pubKey)
            val quotedLine = quoteShell(keyLine)
            val quotedBody = quoteShell(keyBody)
            return """
                set -e
                mkdir -p /data/misc/adb
                chmod 0775 /data/misc/adb
                chown system:shell /data/misc/adb 2>/dev/null || true
                KEYS=/data/misc/adb/adb_keys
                touch "${'$'}KEYS"
                KEY_LINE=$quotedLine
                KEY_BODY=$quotedBody
                NEED_RESTART=0
                if ! grep -Fq "${'$'}KEY_BODY" "${'$'}KEYS" 2>/dev/null; then
                  printf '\n%s\n' "${'$'}KEY_LINE" >> "${'$'}KEYS"
                  NEED_RESTART=1
                fi
                chmod 0640 "${'$'}KEYS"
                chown system:shell "${'$'}KEYS" 2>/dev/null || true
                restorecon "${'$'}KEYS" 2>/dev/null || true
                if command -v iptables >/dev/null 2>&1; then
                  iptables -C INPUT -p tcp --dport $port ! -s 127.0.0.1 -j DROP 2>/dev/null || iptables -I INPUT -p tcp --dport $port ! -s 127.0.0.1 -j DROP 2>/dev/null || true
                fi
                if command -v ip6tables >/dev/null 2>&1; then
                  ip6tables -C INPUT -p tcp --dport $port ! -s ::1 -j DROP 2>/dev/null || ip6tables -I INPUT -p tcp --dport $port ! -s ::1 -j DROP 2>/dev/null || true
                fi
                if [ "${'$'}(getprop service.adb.tcp.port)" != "$port" ] || [ "${'$'}(getprop init.svc.adbd)" != "running" ] || [ "${'$'}NEED_RESTART" = "1" ]; then
                  setprop service.adb.tcp.port $port
                  stop adbd
                  start adbd
                fi
                printf 'adb_loopback_ready=127.0.0.1:%d\n' $port
            """.trimIndent()
        }

        private fun readLineBounded(input: InputStream, maxBytes: Int): String? {
            val buf = ByteArrayOutputStream(256)
            while (true) {
                val b = input.read()
                if (b < 0) return if (buf.size() == 0) null else buf.toString(Charsets.UTF_8.name())
                if (b == '\n'.code) return buf.toString(Charsets.UTF_8.name())
                if (buf.size() >= maxBytes) throw IllegalArgumentException("line exceeds $maxBytes bytes")
                buf.write(b)
            }
        }
    }
}
