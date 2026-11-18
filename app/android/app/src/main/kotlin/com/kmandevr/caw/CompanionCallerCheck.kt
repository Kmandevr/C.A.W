// The companion protocol's caller check (docs/companion-protocol.md), as pure Kotlin with no Android types, so the
// companion app reuses it and a JVM test can run it: one package for the sender's uid, the permission, the signer.
package com.kmandevr.caw

/** What the check reads from the system; `AndroidPackageFacts` (CompanionClient.kt) answers from PackageManager. */
interface PackageFacts {
    /** PackageManager.getPackagesForUid: every package sharing [uid], or null. */
    fun packagesForUid(uid: Int): List<String>?

    /** Whether [pkg] holds [permission] (PackageManager.checkPermission). */
    fun holdsPermission(pkg: String, permission: String): Boolean

    /** API 28+: PackageManager.hasSigningCertificate(uid, sha256, CERT_INPUT_SHA256). */
    fun hasCertificateSha256(uid: Int, sha256: ByteArray): Boolean

    /** API 26 and 27: PackageManager.checkSignatures(uid1, uid2) >= SIGNATURE_MATCH. */
    fun signaturesMatch(uid1: Int, uid2: Int): Boolean
}

object CompanionCallerCheck {
    /** Declared with protectionLevel="signature" and asked for in both apps' manifests. */
    const val PERMISSION = "com.kmandevr.caw.permission.COMPANION"
    const val MAIN_PACKAGE = "com.kmandevr.caw"

    /** [Assumption] until the owner names the companion (docs/companion-protocol.md). */
    const val COMPANION_PACKAGE = "com.kmandevr.caw.companion"
    const val COMPANION_SERVICE = "com.kmandevr.caw.companion.CompanionService"

    /** Android 9 (API 28): hasSigningCertificate. */
    const val API_SIGNING_CERTIFICATE = 28

    enum class Verdict { ALLOWED, NO_SENDER, NOT_ONE_PACKAGE, WRONG_PACKAGE, NO_PERMISSION, WRONG_SIGNER }

    /**
     * Whether a message whose `Message.sendingUid` is [sendingUid] comes from [expectedPackage], signed with this
     * app's own key. [ownCertSha256] is the SHA-256 of each of this app's current signing certificates, read at run
     * time (no digest is written in the source); every one must be the sender's. Below API 28 the signatures of
     * [myUid] and the sender are compared instead.
     */
    fun check(
        sendingUid: Int,
        expectedPackage: String,
        sdkInt: Int,
        myUid: Int,
        ownCertSha256: List<ByteArray>,
        facts: PackageFacts,
    ): Verdict {
        // -1: not posted through a Messenger.
        if (sendingUid < 0) return Verdict.NO_SENDER
        val packages = facts.packagesForUid(sendingUid) ?: return Verdict.NOT_ONE_PACKAGE
        // A shared uid could hold another app's code: exactly one package, the expected one.
        if (packages.size != 1) return Verdict.NOT_ONE_PACKAGE
        if (packages[0] != expectedPackage) return Verdict.WRONG_PACKAGE
        if (!facts.holdsPermission(expectedPackage, PERMISSION)) return Verdict.NO_PERMISSION
        val signed = if (sdkInt >= API_SIGNING_CERTIFICATE) {
            ownCertSha256.isNotEmpty() && ownCertSha256.all { it.size == 32 && facts.hasCertificateSha256(sendingUid, it) }
        } else {
            facts.signaturesMatch(myUid, sendingUid)
        }
        return if (signed) Verdict.ALLOWED else Verdict.WRONG_SIGNER
    }

    /** The bound on a body (UTF-8 bytes), in either direction. */
    const val MAX_BODY_BYTES = 64 * 1024
    const val PROTOCOL_VERSION = 1

    /** Whether [body] fits the protocol's limit. */
    fun bodyFits(body: String?): Boolean =
        body != null && body.length <= MAX_BODY_BYTES && body.toByteArray(Charsets.UTF_8).size <= MAX_BODY_BYTES

    /** A request's timeout in ms, held to what the protocol allows (10 s, 25 s for the relay kinds). */
    fun clampTimeoutMs(asked: Int): Long = asked.coerceIn(1_000, 25_000).toLong()

    /** The message kinds' `what` numbers (1 hello to 10 knownbad.version). */
    fun knownKind(what: Int): Boolean = what in 1..10
}
