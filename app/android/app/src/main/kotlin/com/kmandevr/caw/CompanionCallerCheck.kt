// The companion protocol's caller check (docs/companion-protocol.md), as pure Kotlin with no Android types, so the
// companion app reuses it and a JVM test can run it: one package for the sender's uid, then its signer against a
// pinned certificate digest (and a permission, only when one is asked for).
package com.kmandevr.caw

/** What the check reads from the system; `AndroidPackageFacts` (CompanionClient.kt) answers from PackageManager. */
interface PackageFacts {
    /** PackageManager.getPackagesForUid: every package sharing [uid], or null. */
    fun packagesForUid(uid: Int): List<String>?

    /** Whether [pkg] holds [permission] (PackageManager.checkPermission). */
    fun holdsPermission(pkg: String, permission: String): Boolean

    /** PackageManager.getPackageUid(pkg, 0): the uid [pkg] runs as now, or null when it isn't installed. */
    fun uidOf(pkg: String): Int?

    /** API 28+: PackageManager.hasSigningCertificate(uid, sha256, CERT_INPUT_SHA256). */
    fun hasCertificateSha256(uid: Int, sha256: ByteArray): Boolean

    /**
     * The SHA-256 of each of [pkg]'s current signing certificates, or null when it can't be read: API 28+
     * `SigningInfo.apkContentsSigners`, API 26 and 27 `PackageInfo.signatures`.
     */
    fun currentSignerSha256(pkg: String): List<ByteArray>?
}

object CompanionCallerCheck {
    /**
     * The signature permission the design names. Not declared by the main app (a hostile app declaring it first would
     * make C.A.W's own install fail): whether the companion declares and enforces it is open (docs/companion-protocol.md).
     */
    const val PERMISSION = "com.kmandevr.caw.permission.COMPANION"
    const val MAIN_PACKAGE = "com.kmandevr.caw"

    /** The companion is the AutoStacc Hub (owner, 2026-11-18). */
    const val COMPANION_PACKAGE = "com.autostacc.hub"
    const val COMPANION_SERVICE = "com.autostacc.hub.CompanionService"

    /** Android 9 (API 28): hasSigningCertificate. */
    const val API_SIGNING_CERTIFICATE = 28

    enum class Verdict { ALLOWED, NO_PIN, NO_SENDER, NOT_ONE_PACKAGE, WRONG_PACKAGE, NO_PERMISSION, WRONG_SIGNER }

    /**
     * A pinned SHA-256 certificate digest from build configuration: 64 hex digits, or 32 colon-separated pairs, in
     * either case. Null when empty or malformed, which the check treats as "no companion is accepted".
     */
    fun parsePin(text: String?): ByteArray? {
        val t = text?.trim() ?: return null
        val hex = when {
            t.length == 64 -> t
            t.length == 95 && (0 until 31).all { t[3 * it + 2] == ':' } -> t.replace(":", "")
            else -> return null
        }
        if (hex.length != 64 || !hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
        return ByteArray(32) { hex.substring(2 * it, 2 * it + 2).toInt(16).toByte() }
    }

    /**
     * Whether a message whose `Message.sendingUid` is [sendingUid] comes from [expectedPackage], signed with the key
     * whose certificate's SHA-256 is [pinnedSha256]. No pin (null or not 32 bytes): nothing is accepted. The package
     * must have exactly one current signer, and that signer must be the pinned one; on API 28+ the system must also
     * confirm the pin for the uid (hasSigningCertificate). A package signed by several keys is refused, and so is one
     * whose key rotated away from the pin (the pinned key only in its past lineage): the pin then has to follow the
     * rotation. [requiredPermission], when given, must be held too; the main app passes none, since the signer is the
     * boundary.
     */
    fun check(
        sendingUid: Int,
        expectedPackage: String,
        pinnedSha256: ByteArray?,
        sdkInt: Int,
        facts: PackageFacts,
        requiredPermission: String? = null,
    ): Verdict {
        if (pinnedSha256 == null || pinnedSha256.size != 32) return Verdict.NO_PIN
        // -1: not posted through a Messenger.
        if (sendingUid < 0) return Verdict.NO_SENDER
        val packages = facts.packagesForUid(sendingUid) ?: return Verdict.NOT_ONE_PACKAGE
        // A shared uid could hold another app's code: exactly one package, the expected one.
        if (packages.size != 1) return Verdict.NOT_ONE_PACKAGE
        if (packages[0] != expectedPackage) return Verdict.WRONG_PACKAGE
        if (requiredPermission != null && !facts.holdsPermission(expectedPackage, requiredPermission)) {
            return Verdict.NO_PERMISSION
        }
        val signers = facts.currentSignerSha256(expectedPackage)
        val current = signers != null && signers.size == 1 && signers[0].contentEquals(pinnedSha256)
        // API 26 and 27 have no uid-bound check: the signer was read by package name, so the package must still run
        // as the sender's uid after the read (a package replaced in between gets a new uid).
        val system = if (sdkInt < API_SIGNING_CERTIFICATE) facts.uidOf(expectedPackage) == sendingUid
            else facts.hasCertificateSha256(sendingUid, pinnedSha256)
        return if (current && system) Verdict.ALLOWED else Verdict.WRONG_SIGNER
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
