// The on-device C++ compiler's own process (":compiler"): runs one build per request, so a crash only fails that build.
package com.kmandevr.caw

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.os.RemoteException

class CompilerService : Service() {
    private lateinit var thread: HandlerThread
    private lateinit var messenger: Messenger

    override fun onCreate() {
        super.onCreate()
        // Clang's temporary objects go to the app's own cache.
        val tmp = java.io.File(cacheDir, "compiler-tmp").apply { mkdirs() }
        android.system.Os.setenv("TMPDIR", tmp.absolutePath, true)
        thread = HandlerThread("caw-compiler", Process.THREAD_PRIORITY_BACKGROUND).apply { start() }
        messenger = Messenger(object : Handler(thread.looper) {
            override fun handleMessage(msg: Message) {
                if (msg.what != MSG_RUN) return
                val copy = Message.obtain(msg)
                if (!busy.compareAndSet(false, true)) {  // one build per process: LLVM's state is global
                    reply(copy, CODE_BUSY, "error: another C++ build is still running")
                    return
                }
                // Clang recurses deeply (it wants 8 MB of stack); a background thread has about 1 MB.
                Thread(null, { run(copy) }, "caw-compiler-build", 64L shl 20).start()
            }
        })
    }

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    private fun run(msg: Message) {
        // Builds run below the UI and audio: a long compile never takes their time.
        Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
        val replyTo = msg.replyTo ?: return
        val data = msg.data
        val args = data.getStringArray(KEY_ARGS) ?: emptyArray()
        val reply = Bundle()
        try {
            loadLibrary()
            val text = String(nativeRun(args), Charsets.UTF_8)
            val newline = text.indexOf('\n')
            reply.putInt(KEY_CODE, text.substring(0, maxOf(newline, 0)).toIntOrNull() ?: 1)
            reply.putString(KEY_OUTPUT, if (newline >= 0) text.substring(newline + 1) else text)
        } catch (e: UnsatisfiedLinkError) {
            reply.putInt(KEY_CODE, CODE_UNAVAILABLE)
            reply.putString(KEY_OUTPUT, "error: this build of C.A.W does not include the C++ compiler")
        }
        send(replyTo, reply)
        // LLVM keeps global state between runs: every build starts in a fresh process. The short wait
        // lets the reply reach the app before it sees this process end.
        Handler(thread.looper).postDelayed({ Process.killProcess(Process.myPid()) }, 300)
    }

    private val busy = java.util.concurrent.atomic.AtomicBoolean(false)

    private fun reply(msg: Message, code: Int, output: String) {
        val replyTo = msg.replyTo ?: return
        send(replyTo, Bundle().apply {
            putInt(KEY_CODE, code)
            putString(KEY_OUTPUT, output)
        })
    }

    private fun send(replyTo: Messenger, data: Bundle) {
        try {
            replyTo.send(Message.obtain(null, MSG_RESULT).apply { this.data = data })
        } catch (_: RemoteException) {
            // The app went away; nothing waits for this build.
        }
    }

    companion object {
        const val CODE_BUSY = -3
        const val MSG_RUN = 1
        const val MSG_RESULT = 2
        const val KEY_ARGS = "args"
        const val KEY_CODE = "code"
        const val KEY_OUTPUT = "output"
        const val CODE_UNAVAILABLE = -2

        @Volatile private var loaded = false

        private fun loadLibrary() {
            if (!loaded) {
                System.loadLibrary("caw_compiler")
                loaded = true
            }
        }

        @JvmStatic external fun nativeRun(args: Array<String>): ByteArray
    }
}
