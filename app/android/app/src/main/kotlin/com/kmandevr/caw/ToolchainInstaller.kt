// Unpacks the compiler's offline data (headers, sysroot, libraries) from the APK into app storage, once per version.
package com.kmandevr.caw

import android.content.Context
import java.io.File
import java.io.FileNotFoundException
import java.util.zip.ZipInputStream

object ToolchainInstaller {
    private const val ASSET = "caw-toolchain.zip"
    private const val MARKER = ".installed"

    /** The toolchain directory, unpacked if needed; throws if this build has no compiler data. */
    fun install(context: Context): File {
        val version = apkVersion(context)
        val dir = File(context.filesDir, "toolchain")
        val marker = File(dir, MARKER)
        if (marker.isFile && marker.readText() == version) return dir
        val staging = File(context.filesDir, "toolchain.partial")
        staging.deleteRecursively()
        staging.mkdirs()
        val root = staging.canonicalPath + File.separator
        try {
            context.assets.open(ASSET).use { raw ->
                ZipInputStream(raw.buffered()).use { zip ->
                    while (true) {
                        val entry = zip.nextEntry ?: break
                        val target = File(staging, entry.name)
                        // Never outside the toolchain directory, whatever the archive says.
                        if (!target.canonicalPath.startsWith(root)) throw SecurityException("unsafe path in toolchain data: ${entry.name}")
                        if (entry.isDirectory) {
                            target.mkdirs()
                        } else {
                            target.parentFile?.mkdirs()
                            target.outputStream().use { zip.copyTo(it) }
                        }
                    }
                }
            }
        } catch (e: FileNotFoundException) {
            staging.deleteRecursively()
            throw IllegalStateException("this build of C.A.W does not include the C++ compiler")
        }
        File(staging, MARKER).writeText(version)
        dir.deleteRecursively()
        if (!staging.renameTo(dir)) throw IllegalStateException("could not install the C++ toolchain")
        return dir
    }

    // A new APK may carry new toolchain data: its install time marks the version.
    private fun apkVersion(context: Context): String {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        return "${info.lastUpdateTime}"
    }
}
