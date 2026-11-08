package io.github.ccch1mneyyy.dsh_app.phone

import io.github.ccch1mneyyy.dsh_app.runtime.GuestSetup
import java.io.File
import java.net.Socket
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class RootCliBridgeTest {
    private val sampleKeyBody = "QAAAAD0x23456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+/=="
    private val samplePubKey = "$sampleKeyBody root@dsh-container"

    @Test fun rejectsMissingOrWrongTokenWithoutRunningCommand() {
        var called = false
        val bridge = RootCliBridge({ _, _ ->
            called = true
            RootCliBridge.ExecResult(0, "should not run", "")
        })
        val badToken = bridge.handleRequest(
            Json.write(mapOf("token" to "wrong", "op" to "exec", "cmd" to "id")),
            "expected-secret-token",
        )
        assertFalse(called)
        assertEquals(false, badToken["ok"])
        assertEquals(126, badToken["exitCode"])
        assertEquals("unauthorized", badToken["error"])
    }

    @Test fun executesHostCommandAndClampsTimeout() {
        val capturedCmd = AtomicReference<String>()
        val capturedTimeout = AtomicReference<Long>()
        val bridge = RootCliBridge({ cmd, timeoutMs ->
            capturedCmd.set(cmd)
            capturedTimeout.set(timeoutMs)
            RootCliBridge.ExecResult(exitCode = 0, stdout = "uid=0(root)\n", stderr = "")
        })
        val res = bridge.handleRequest(
            Json.write(mapOf("token" to "tok123", "op" to "exec", "cmd" to "id", "timeoutMs" to 999_999_999L)),
            "tok123",
        )
        assertEquals(true, res["ok"])
        assertEquals(0, res["exitCode"])
        assertEquals("uid=0(root)\n", res["stdout"])
        assertEquals("id", capturedCmd.get())
        assertEquals(RootCliBridge.MAX_TIMEOUT_MS, capturedTimeout.get())
    }

    @Test fun validatesAdbPublicKeyAndPort() {
        for (badKey in listOf("", "short", "not_base64!@#$ root@host", "$sampleKeyBody\nsecond-line")) {
            try {
                RootCliBridge.bootstrapAdbScript(badKey, 5555)
                fail("expected rejection for key: $badKey")
            } catch (_: IllegalArgumentException) {
            }
        }
        for (badPort in listOf(0, 80, 1023, 65536)) {
            try {
                RootCliBridge.bootstrapAdbScript(samplePubKey, badPort)
                fail("expected rejection for port: $badPort")
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    @Test fun bootstrapAdbScriptQuotesKeyCommentAndEnforcesLoopbackFirewall() {
        val marker = File.createTempFile("adb-key-quote-", ".must-not-exist").apply { delete() }
        val trickyCommentKey = "$sampleKeyBody user'$(touch ${marker.path})`touch ${marker.path}`@host"
        val script = RootCliBridge.bootstrapAdbScript(trickyCommentKey, 5555)
        assertTrue(script.contains("/data/misc/adb/adb_keys"))
        assertTrue(script.contains("iptables -C INPUT -p tcp --dport 5555 ! -s 127.0.0.1 -j DROP"))
        assertTrue(script.contains("ip6tables -C INPUT -p tcp --dport 5555 ! -s ::1 -j DROP"))
        assertTrue(script.contains("setprop service.adb.tcp.port 5555"))

        val keyLineAssign = script.lines().first { it.startsWith("KEY_LINE=") }
        val keyBodyAssign = script.lines().first { it.startsWith("KEY_BODY=") }
        val proc = ProcessBuilder(
            "/bin/sh",
            "-c",
            "$keyLineAssign; $keyBodyAssign; printf '%s\\n%s' \"\$KEY_BODY\" \"\$KEY_LINE\"",
        ).start()
        val output = proc.inputStream.bufferedReader().readText()
        assertEquals(0, proc.waitFor())
        assertEquals("$sampleKeyBody\n$trickyCommentKey", output)
        assertFalse(marker.exists())
    }

    @Test fun writesGuestFilesAndServesRequestsOverLoopbackSocket() {
        val root = Files.createTempDirectory("root-cli-guest").toFile()
        val lastCmd = AtomicReference<String>()
        val bridge = RootCliBridge({ cmd, _ ->
            lastCmd.set(cmd)
            RootCliBridge.ExecResult(0, "ok:$cmd\n", "")
        })
        try {
            RootCliGuest.writeFiles(root)
            val hostSu = File(root, RootCliGuest.HOST_SU_BIN.removePrefix("/"))
            val adbBootstrap = File(root, RootCliGuest.ADB_BOOTSTRAP_BIN.removePrefix("/"))
            val androidInstall = File(root, RootCliGuest.ANDROID_CLI_INSTALL_BIN.removePrefix("/"))
            val clientCjs = File(root, RootCliGuest.CLIENT_SCRIPT.removePrefix("/"))
            assertTrue(hostSu.canExecute())
            assertTrue(adbBootstrap.canExecute())
            assertTrue(androidInstall.canExecute())
            assertTrue(clientCjs.isFile)

            val ep = bridge.start(withTcp = true, bindAbstractSocket = false)
            val port = ep.tcpPort ?: error("expected tcpPort")
            RootCliGuest.writeConfig(root, ep)
            val cfgFile = File(root, RootCliGuest.CONFIG_FILE.removePrefix("/"))
            assertTrue(cfgFile.isFile)

            Socket("127.0.0.1", port).use { sock ->
                val req = Json.write(mapOf("token" to ep.token, "op" to "exec", "cmd" to "getprop ro.product.model")) + "\n"
                sock.getOutputStream().write(req.toByteArray(Charsets.UTF_8))
                sock.getOutputStream().flush()
                val replyLine = sock.getInputStream().bufferedReader().readLine()
                val reply = Json.parse(replyLine) as Map<*, *>
                assertEquals(true, reply["ok"])
                assertEquals("ok:getprop ro.product.model\n", reply["stdout"])
            }
            assertEquals(1, bridge.authenticatedConnections)
        } finally {
            bridge.stop()
            RootCliGuest.clearConfig(root)
            assertFalse(File(root, RootCliGuest.CONFIG_FILE.removePrefix("/")).exists())
            root.deleteRecursively()
        }
    }

    @Test fun nodeClientCjsExecutesHostSuAndBootstrapAdbEndToEnd() {
        val node = listOfNotNull(
            System.getenv("NODE_BINARY"),
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
            System.getenv("PATH")?.split(File.pathSeparator)?.map { File(it, "node").path }?.firstOrNull { File(it).canExecute() },
        ).firstOrNull { File(it).canExecute() } ?: return

        val root = Files.createTempDirectory("root-cli-node").toFile()
        val executed = mutableListOf<String>()
        val bridge = RootCliBridge({ cmd, _ ->
            executed += cmd
            if (cmd == "fail-42") {
                RootCliBridge.ExecResult(42, "", "permission denied\n")
            } else {
                RootCliBridge.ExecResult(0, "ran:$cmd\n", "")
            }
        })
        try {
            RootCliGuest.writeFiles(root)
            val ep = bridge.start(withTcp = true, bindAbstractSocket = false)
            RootCliGuest.writeConfig(root, ep)
            val clientPath = File(root, RootCliGuest.CLIENT_SCRIPT.removePrefix("/")).path

            val okProc = ProcessBuilder(node, clientPath, "-c", "id -u").apply {
                environment()["DSH_GO_DIRECT_ROOTFS"] = root.path
            }.start()
            assertEquals(0, okProc.waitFor())
            assertEquals("ran:id -u\n", okProc.inputStream.bufferedReader().readText())

            val failProc = ProcessBuilder(node, clientPath, "fail-42").apply {
                environment()["DSH_GO_DIRECT_ROOTFS"] = root.path
            }.start()
            assertEquals(42, failProc.waitFor())
            assertEquals("permission denied\n", failProc.errorStream.bufferedReader().readText())

            val pubKeyFile = File(root, "adbkey.pub").apply { writeText("$samplePubKey\n") }
            val adbProc = ProcessBuilder(node, clientPath, "--bootstrap-adb", pubKeyFile.path, "--port", "5555").apply {
                environment()["DSH_GO_DIRECT_ROOTFS"] = root.path
            }.start()
            assertEquals(0, adbProc.waitFor())
            assertTrue(executed.last().contains("/data/misc/adb/adb_keys"))
        } finally {
            bridge.stop()
            root.deleteRecursively()
        }
    }

    @Test fun agentsMdDocumentsHostSuAdbBootstrapAndAndroidCli() {
        val root = Files.createTempDirectory("root-cli-agents").toFile()
        try {
            GuestSetup.writeAgentsMd(root, phoneStorage = false)
            val text = File(root, "root/.dsh/AGENTS.md").readText()
            assertTrue(text.contains("`host-su -c \"<命令>\"`"))
            assertTrue(text.contains("`dsh-adb-bootstrap`"))
            assertTrue(text.contains("`dsh-android-cli-install`"))
            assertTrue(text.contains("`android layout`"))
        } finally {
            root.deleteRecursively()
        }
    }
}
