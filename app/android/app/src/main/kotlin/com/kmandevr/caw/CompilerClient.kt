// Main-process side of the compiler: sends one build to CompilerService and reports its result, or its crash.
package com.kmandevr.caw

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.RemoteException

class CompilerClient(private val context: Context) {
    /** Runs clang's [args] in the compiler process; [done] gets (exit code, diagnostics) on the main thread. */
    fun run(args: List<String>, done: (Int, String) -> Unit) {
        val main = Handler(Looper.getMainLooper())
        var finished = false
        lateinit var connection: ServiceConnection
        fun finish(code: Int, output: String) {
            if (finished) return
            finished = true
            try {
                context.unbindService(connection)
            } catch (_: IllegalArgumentException) {
            }
            done(code, output)
        }
        val replies = Messenger(object : Handler(Looper.getMainLooper()) {
            override fun handleMessage(msg: Message) {
                if (msg.what == CompilerService.MSG_RESULT) {
                    finish(msg.data.getInt(CompilerService.KEY_CODE, 1), msg.data.getString(CompilerService.KEY_OUTPUT) ?: "")
                }
            }
        })
        connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                val request = Message.obtain(null, CompilerService.MSG_RUN).apply {
                    data = Bundle().apply { putStringArray(CompilerService.KEY_ARGS, args.toTypedArray()) }
                    replyTo = replies
                }
                try {
                    Messenger(binder).send(request)
                } catch (_: RemoteException) {
                    finish(CODE_CRASHED, CRASHED)
                }
            }

            // The compiler process died before it answered: a crash in the compiler, or the system killed it.
            override fun onServiceDisconnected(name: ComponentName?) = main.post { finish(CODE_CRASHED, CRASHED) }.let {}
            override fun onBindingDied(name: ComponentName?) = main.post { finish(CODE_CRASHED, CRASHED) }.let {}
        }
        val bound = context.bindService(Intent(context, CompilerService::class.java), connection, Context.BIND_AUTO_CREATE)
        if (!bound) finish(CODE_CRASHED, "error: the C++ compiler process could not start")
    }

    companion object {
        const val CODE_CRASHED = -1
        private const val CRASHED = "error: the C++ compiler stopped unexpectedly; this build failed, nothing else is affected"
    }
}
