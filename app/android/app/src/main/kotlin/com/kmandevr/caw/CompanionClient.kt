// The main app's side of the companion protocol (docs/companion-protocol.md): binds the companion's service (3 s),
// sends one Message per request, checks each reply's sender (CompanionCallerCheck.kt), times requests out and
// unbinds when idle. Answers the caw/companion channel; with no companion installed every answer is "absent".
package com.kmandevr.caw

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.os.RemoteException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/** [PackageFacts] from the system's PackageManager. */
class AndroidPackageFacts(private val pm: PackageManager) : PackageFacts {
    override fun packagesForUid(uid: Int): List<String>? = pm.getPackagesForUid(uid)?.toList()

    override fun holdsPermission(pkg: String, permission: String): Boolean =
        pm.checkPermission(permission, pkg) == PackageManager.PERMISSION_GRANTED

    override fun hasCertificateSha256(uid: Int, sha256: ByteArray): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            pm.hasSigningCertificate(uid, sha256, PackageManager.CERT_INPUT_SHA256)

    override fun signaturesMatch(uid1: Int, uid2: Int): Boolean = pm.checkSignatures(uid1, uid2) >= PackageManager.SIGNATURE_MATCH
}

class CompanionClient(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val facts = AndroidPackageFacts(context.packageManager)
    private val ownCerts: List<ByteArray> by lazy { readOwnCertificates() }

    private class Pending(
        val what: Int, val timeoutMs: Int, val done: (Map<String, Any?>) -> Unit, val timeout: Runnable, val message: Message,
    )

    private val pending = LinkedHashMap<Int, Pending>()
    private var connection: ServiceConnection? = null
    private var service: Messenger? = null
    private var bindTimeout: Runnable? = null
    private val idleUnbind = Runnable { unbind() }

    private val replies = Messenger(object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(msg: Message) = onReply(msg)
    })

    /** The caw/companion channel: `request` with what, v, id, body (JSON text) and timeoutMs. */
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "request") return result.notImplemented()
        val what = call.argument<Int>("what") ?: -1
        val id = call.argument<Int>("id") ?: -1
        val body = call.argument<String>("body")
        val timeoutMs = call.argument<Int>("timeoutMs") ?: 10_000
        if (!CompanionCallerCheck.knownKind(what) || !CompanionCallerCheck.bodyFits(body)) {
            return result.error("bad_request", "not a companion request", null)
        }
        request(what, id, body!!, timeoutMs) { answer -> result.success(answer) }
    }

    /** Sends one request; [done] gets the answer map on the main thread, exactly once. */
    fun request(what: Int, id: Int, body: String, timeoutMs: Int, done: (Map<String, Any?>) -> Unit) {
        main.removeCallbacks(idleUnbind)
        if (pending.containsKey(id)) return done(mapOf("outcome" to "absent"))
        if (!companionLooksRight()) return done(mapOf("outcome" to "absent"))
        val message = Message.obtain(null, what).apply {
            data = Bundle().apply {
                putInt(KEY_V, CompanionCallerCheck.PROTOCOL_VERSION)
                putInt(KEY_ID, id)
                putString(KEY_BODY, body)
            }
            replyTo = replies
        }
        val timeout = Runnable { finish(id, mapOf("outcome" to "timeout")) }
        pending[id] = Pending(what, timeoutMs, done, timeout, message)
        val bound = service
        // Sent once bound (bind() times out in 3 s); the request's own timeout starts when it is sent.
        if (bound != null) send(bound, id) else bind()
    }

    /** Whether the companion is installed, visible (<queries>) and signed with this app's key: no bind otherwise. */
    private fun companionLooksRight(): Boolean {
        val uid = try {
            context.packageManager.getPackageUid(CompanionCallerCheck.COMPANION_PACKAGE, 0)
        } catch (_: PackageManager.NameNotFoundException) {
            return false
        }
        return CompanionCallerCheck.check(uid, CompanionCallerCheck.COMPANION_PACKAGE, Build.VERSION.SDK_INT,
            Process.myUid(), ownCerts, facts) == CompanionCallerCheck.Verdict.ALLOWED
    }

    private fun bind() {
        if (connection != null) return
        val c = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                bindTimeout?.let { main.removeCallbacks(it) }
                bindTimeout = null
                if (binder == null) return dropAll("absent")
                val m = Messenger(binder)
                service = m
                for (id in pending.keys.toList()) send(m, id)
            }

            // The companion's process died: a request in flight may have been acted on, so it times out (never
            // retried in-app); the next request binds again.
            override fun onServiceDisconnected(name: ComponentName?) {
                unbind()
                dropAll("timeout")
            }

            override fun onBindingDied(name: ComponentName?) {
                unbind()
                dropAll("timeout")
            }

            override fun onNullBinding(name: ComponentName?) {
                unbind()
                dropAll("absent")
            }
        }
        connection = c
        val intent = Intent().setComponent(ComponentName(CompanionCallerCheck.COMPANION_PACKAGE, CompanionCallerCheck.COMPANION_SERVICE))
        val ok = try {
            context.bindService(intent, c, Context.BIND_AUTO_CREATE)
        } catch (_: SecurityException) {
            false // the service asks for a permission this build doesn't hold
        }
        if (!ok) {
            unbind()
            return dropAll("absent")
        }
        val t = Runnable {
            unbind()
            dropAll("absent")
        }
        bindTimeout = t
        main.postDelayed(t, BIND_TIMEOUT_MS)
    }

    private fun send(to: Messenger, id: Int) {
        val p = pending[id] ?: return
        main.postDelayed(p.timeout, CompanionCallerCheck.clampTimeoutMs(p.timeoutMs))
        try {
            to.send(p.message)
        } catch (_: RemoteException) {
            finish(id, mapOf("outcome" to "absent"))
        }
    }

    private fun onReply(msg: Message) {
        // A Bundle from another process may hold classes this app can't read: such a reply is dropped (it times out).
        val data = try {
            msg.data.also { it.getInt(KEY_ID, -1) }
        } catch (_: RuntimeException) {
            return
        }
        val id = data.getInt(KEY_ID, -1)
        val p = pending[id] ?: return
        val sender = CompanionCallerCheck.check(msg.sendingUid, CompanionCallerCheck.COMPANION_PACKAGE, Build.VERSION.SDK_INT,
            Process.myUid(), ownCerts, facts)
        if (sender != CompanionCallerCheck.Verdict.ALLOWED) return finish(id, mapOf("outcome" to "refused"))
        if (msg.what != p.what) return finish(id, mapOf("outcome" to "refused"))
        val body = data.getString(KEY_BODY)
        finish(id, mapOf(
            "outcome" to "reply",
            "v" to data.getInt(KEY_V, 0),
            "id" to id,
            "status" to data.getString(KEY_STATUS),
            "body" to if (CompanionCallerCheck.bodyFits(body)) body else null,
        ))
    }

    private fun finish(id: Int, answer: Map<String, Any?>) {
        val p = pending.remove(id) ?: return
        main.removeCallbacks(p.timeout)
        p.done(answer)
        if (pending.isEmpty()) main.postDelayed(idleUnbind, IDLE_UNBIND_MS)
    }

    private fun dropAll(outcome: String) {
        for (id in pending.keys.toList()) finish(id, mapOf("outcome" to outcome))
    }

    private fun unbind() {
        bindTimeout?.let { main.removeCallbacks(it) }
        bindTimeout = null
        val c = connection ?: return
        connection = null
        service = null
        try {
            context.unbindService(c)
        } catch (_: IllegalArgumentException) {
        }
    }

    /** Ends every request and the binding (the activity is going). */
    fun dispose() {
        dropAll("absent")
        main.removeCallbacks(idleUnbind)
        unbind()
    }

    /** SHA-256 of each of this app's current signing certificates (API 28+); empty below, where checkSignatures runs. */
    private fun readOwnCertificates(): List<ByteArray> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return emptyList()
        return try {
            val info = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
            val signers = info.signingInfo?.apkContentsSigners ?: return emptyList()
            signers.map { MessageDigest.getInstance("SHA-256").digest(it.toByteArray()) }
        } catch (_: PackageManager.NameNotFoundException) {
            emptyList()
        }
    }

    companion object {
        private const val KEY_V = "v"
        private const val KEY_ID = "id"
        private const val KEY_BODY = "body"
        private const val KEY_STATUS = "status"
        private const val BIND_TIMEOUT_MS = 3_000L
        private const val IDLE_UNBIND_MS = 30_000L
    }
}
