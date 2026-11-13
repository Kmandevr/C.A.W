// The music video's MP4 encoder (`caw/video`): RGBA frames to H.264 with MediaCodec (through its input Surface where it can), a 16-bit WAV to AAC, both muxed by MediaMuxer.
package com.kmandevr.caw

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.Executors

/**
 * Methods (all run on one worker thread, in order; replies come back on the main thread):
 * - `caps`: {maxLong, maxShort}, the largest frame the first H.264 encoder takes either way round.
 * - `start` {width, height, fps, bitrate, audio (a 16-bit PCM WAV), output}: picks an H.264 encoder that takes the
 *   size, encodes the whole audio to AAC-LC first (kept in memory: about 20 KB a second), and opens the muxer.
 * - `frame` {rgba}: one frame, width × height × 4 bytes, top row first (the method-channel path, kept for callers
 *   that still use it). The `caw/video_frame` binary channel takes the same bytes without the codec's copy and
 *   replies one byte: 0, or 1 and the error's UTF-8 text.
 * - `finish`: ends the stream and closes the file. `cancel`: stops and deletes the file.
 *
 * Frames go in through the codec's input Surface where it has one (COLOR_FormatSurface): an EGL context (GLES 2) on
 * that Surface uploads the RGBA bytes as a texture and draws it, so the GPU converts them to the codec's YUV, and
 * each frame is stamped explicitly with eglPresentationTimeANDROID at its index × 1e9 / fps: the encoder's rate
 * control and the file see exact frame times, never when the frame happened to be posted. Where the Surface or its
 * EGL context can't be had, or its first frame fails, the frame is converted to YUV 4:2:0 (BT.601) on the CPU a row
 * at a time into the codec's input Image.
 *
 * Platform APIs only, no library (Android Developers, read 2026-11-11 to 2026-11-13): MediaCodec (getInputImage
 * API 21, createInputSurface API 18, signalEndOfInputStream API 18, COLOR_FormatYUV420Flexible and
 * COLOR_FormatSurface API 21/18), EGL14 (API 17), EGLExt.eglPresentationTimeANDROID (API 18) and
 * EGLExt.EGL_RECORDABLE_ANDROID (API 26, the app's minSdk), GLES20 (API 8), MediaMuxer (MPEG-4 output API 18),
 * MediaCodecList (API 21): developer.android.com/reference/android/media/MediaCodec, .../android/opengl/EGLExt,
 * .../android/opengl/EGL14, .../android/opengl/GLES20, .../MediaMuxer, .../MediaCodecList.
 */
class VideoEncoder : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var session: Session? = null

    // Two frame buffers taken in turn on the main thread: Dart sends a frame only after the last one's reply, so the
    // worker is done with a buffer before it comes round again (no 8 MB allocation a frame).
    private val spare = arrayOfNulls<ByteBuffer>(2)
    private var turn = 0

    /** The binary frame channel: the bytes are copied once (the message is only valid during this call). */
    val frameHandler = BinaryMessenger.BinaryMessageHandler { message, reply ->
        val copy = message?.let { m ->
            m.rewind()
            turn = 1 - turn
            val held = spare[turn]
            val b = if (held != null && held.capacity() == m.remaining()) held
                else ByteBuffer.allocateDirect(m.remaining()).also { spare[turn] = it }
            b.clear()
            b.put(m)
            b.rewind()
            b
        }
        worker.execute {
            val out = try {
                val s = session ?: throw IllegalStateException("not started")
                s.frame(copy ?: throw IllegalArgumentException("no frame"))
                // A reply's length is its position, so it isn't rewound.
                ByteBuffer.allocateDirect(1).also { it.put(0) }
            } catch (e: Exception) {
                val text = (e.message ?: e.javaClass.simpleName).toByteArray(Charsets.UTF_8)
                ByteBuffer.allocateDirect(1 + text.size).also { it.put(1); it.put(text) }
            }
            main.post { reply.reply(out) }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "caps" -> run(result) { caps() }
            "start" -> {
                val w = call.argument<Int>("width") ?: 0
                val h = call.argument<Int>("height") ?: 0
                val fps = call.argument<Int>("fps") ?: 30
                val bitrate = call.argument<Int>("bitrate") ?: 8_000_000
                val audio = call.argument<String>("audio") ?: ""
                val output = call.argument<String>("output") ?: ""
                run(result) {
                    session?.cancel()
                    session = null
                    session = Session(w, h, fps, bitrate, audio, output).also { it.start() }
                    null
                }
            }
            "frame" -> {
                val rgba = call.argument<ByteArray>("rgba")
                run(result) {
                    val s = session ?: throw IllegalStateException("not started")
                    s.frame(ByteBuffer.wrap(rgba ?: throw IllegalArgumentException("no frame")))
                    null
                }
            }
            "finish" -> run(result.also { spare.fill(null) }) {
                val s = session ?: throw IllegalStateException("not started")
                session = null
                s.finish()
                null
            }
            "cancel" -> run(result.also { spare.fill(null) }) {
                session?.cancel()
                session = null
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun run(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("video", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    private fun caps(): Map<String, Int> {
        val info = avcEncoders().firstOrNull() ?: return mapOf("maxLong" to 0, "maxShort" to 0)
        val v = info.getCapabilitiesForType(AVC).videoCapabilities
        val w = v.supportedWidths.upper
        val h = v.supportedHeights.upper
        return mapOf("maxLong" to maxOf(w, h), "maxShort" to minOf(w, h))
    }

    companion object {
        const val AVC = MediaFormat.MIMETYPE_VIDEO_AVC
        const val AAC = MediaFormat.MIMETYPE_AUDIO_AAC
        const val TIMEOUT_US = 10_000L

        fun avcEncoders(): List<MediaCodecInfo> = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { info ->
            info.isEncoder && info.supportedTypes.any { it.equals(AVC, ignoreCase = true) } &&
                info.getCapabilitiesForType(AVC).colorFormats.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
        }
    }

    /** One encode: the video codec (fed through its Surface or its input Images), the AAC samples waiting for the
     * muxer, and the muxer. */
    private class Session(
        val width: Int, val height: Int, val fps: Int, val bitrate: Int, val audioPath: String, val outputPath: String,
    ) {
        private var video: MediaCodec? = null
        private var muxer: MediaMuxer? = null
        private var audioFormat: MediaFormat? = null
        private var audioSamples: MutableList<Pair<ByteArray, MediaCodec.BufferInfo>>? = mutableListOf()
        private var videoTrack = -1
        private var audioTrack = -1
        private var muxing = false
        private var frames = 0L
        private val info = MediaCodec.BufferInfo()
        private var codecInfo: MediaCodecInfo? = null

        // The Surface path: the codec's input Surface and the EGL context drawing frames onto it.
        private var surface: Surface? = null
        private var egl: EglInput? = null

        // The CPU path's rows, reused frame to frame.
        private var rgbaRows: ByteArray? = null
        private var yRow: ByteArray? = null
        private var uRow: ByteArray? = null
        private var vRow: ByteArray? = null

        fun start() {
            try {
                open()
            } catch (e: Exception) {
                cancel()
                throw e
            }
        }

        private fun open() {
            if (width <= 0 || height <= 0 || width % 2 != 0 || height % 2 != 0) throw IllegalArgumentException("bad size")
            val ci = avcEncoders().firstOrNull {
                it.getCapabilitiesForType(AVC).videoCapabilities.isSizeSupported(width, height)
            } ?: throw IllegalArgumentException("no H.264 encoder here takes ${width}x$height")
            codecInfo = ci
            encodeAudio()
            val surfaceOk = ci.getCapabilitiesForType(AVC).colorFormats
                .contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            if (!(surfaceOk && openCodec(useSurface = true))) openCodec(useSurface = false)
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        }

        /** Configures and starts the codec for Surface or Image input; false when the Surface path can't start. */
        private fun openCodec(useSurface: Boolean): Boolean {
            val format = MediaFormat.createVideoFormat(AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, if (useSurface) MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
                    else MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
            val codec = MediaCodec.createByCodecName(codecInfo!!.name)
            try {
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                if (useSurface) surface = codec.createInputSurface()
                codec.start()
                if (useSurface) egl = EglInput(surface!!, width, height)
            } catch (e: Exception) {
                egl?.release()
                egl = null
                surface?.release()
                surface = null
                try { codec.stop() } catch (x: Exception) {}
                codec.release()
                if (useSurface) return false
                throw e
            }
            video = codec
            return true
        }

        fun frame(rgba: ByteBuffer) {
            if (rgba.capacity() != width * height * 4) throw IllegalArgumentException("frame is ${rgba.capacity()} bytes")
            if (surface != null) {
                try {
                    surfaceFrame(rgba)
                    return
                } catch (e: Exception) {
                    // A Surface that fails at its first frame: the CPU path from the start instead.
                    if (frames > 0) throw e
                    closeSurfaceCodec()
                    openCodec(useSurface = false)
                }
            }
            bufferFrame(rgba)
        }

        private fun closeSurfaceCodec() {
            try { video?.stop() } catch (e: Exception) {}
            try { video?.release() } catch (e: Exception) {}
            video = null
            egl?.release()
            egl = null
            surface?.release()
            surface = null
        }

        /** One frame onto the Surface at exactly its frame time (the codec gives it back in microseconds, which is
         * frames × 1e6 / fps, the same time the CPU path queues). */
        private fun surfaceFrame(rgba: ByteBuffer) {
            val e = egl ?: throw IllegalStateException("no EGL context")
            // Take what is ready first, so the codec has room for this frame (not before the first: the muxer must
            // not start on this codec's format while a failing first frame can still switch to the CPU path).
            if (frames > 0) drain(false)
            e.draw(rgba, frames * 1_000_000_000L / fps)
            frames++
            drain(false)
        }

        private fun bufferFrame(rgba: ByteBuffer) {
            val codec = video ?: throw IllegalStateException("not started")
            var index = codec.dequeueInputBuffer(TIMEOUT_US)
            while (index < 0) {
                drain(false)
                index = codec.dequeueInputBuffer(TIMEOUT_US)
            }
            val image = codec.getInputImage(index) ?: throw IllegalStateException("the encoder gave no input image")
            val planes = image.planes
            val y = planes[0]
            val u = planes[1]
            val v = planes[2]
            val yb = y.buffer
            val ub = u.buffer
            val vb = v.buffer
            // Two rows of RGBA at a time (a chroma row's worth), read in one go; rows written whole where the plane
            // is packed (pixel stride 1), else a byte at a time.
            val rowBytes = width * 4
            val rows = rgbaRows ?: ByteArray(rowBytes * 2).also { rgbaRows = it }
            val yr = yRow ?: ByteArray(width).also { yRow = it }
            val half = width / 2
            val ur = uRow ?: ByteArray(half).also { uRow = it }
            val vr = vRow ?: ByteArray(half).also { vRow = it }
            for (pair in 0 until height / 2) {
                rgba.position(pair * 2 * rowBytes)
                rgba.get(rows, 0, rowBytes * 2)
                for (dy in 0..1) {
                    val base = dy * rowBytes
                    for (col in 0 until width) {
                        val p = base + col * 4
                        val r = rows[p].toInt() and 0xff
                        val g = rows[p + 1].toInt() and 0xff
                        val bl = rows[p + 2].toInt() and 0xff
                        yr[col] = (((66 * r + 129 * g + 25 * bl + 128) shr 8) + 16).toByte()
                    }
                    putRow(yb, (pair * 2 + dy) * y.rowStride, y.pixelStride, yr, width)
                }
                for (col in 0 until half) {
                    val p0 = col * 8
                    val p1 = rowBytes + col * 8
                    val r = ((rows[p0].toInt() and 0xff) + (rows[p0 + 4].toInt() and 0xff) +
                        (rows[p1].toInt() and 0xff) + (rows[p1 + 4].toInt() and 0xff)) shr 2
                    val g = ((rows[p0 + 1].toInt() and 0xff) + (rows[p0 + 5].toInt() and 0xff) +
                        (rows[p1 + 1].toInt() and 0xff) + (rows[p1 + 5].toInt() and 0xff)) shr 2
                    val bl = ((rows[p0 + 2].toInt() and 0xff) + (rows[p0 + 6].toInt() and 0xff) +
                        (rows[p1 + 2].toInt() and 0xff) + (rows[p1 + 6].toInt() and 0xff)) shr 2
                    ur[col] = (((-38 * r - 74 * g + 112 * bl + 128) shr 8) + 128).toByte()
                    vr[col] = (((112 * r - 94 * g - 18 * bl + 128) shr 8) + 128).toByte()
                }
                putRow(ub, pair * u.rowStride, u.pixelStride, ur, half)
                putRow(vb, pair * v.rowStride, v.pixelStride, vr, half)
            }
            val pts = frames * 1_000_000L / fps
            codec.queueInputBuffer(index, 0, width * height * 3 / 2, pts, 0)
            frames++
            drain(false)
        }

        /** [n] bytes of [row] into [buf] from [at], [stride] apart (one bulk copy when they are packed). */
        private fun putRow(buf: ByteBuffer, at: Int, stride: Int, row: ByteArray, n: Int) {
            if (stride == 1) {
                buf.position(at)
                buf.put(row, 0, n)
            } else {
                for (i in 0 until n) buf.put(at + i * stride, row[i])
            }
        }

        fun finish() {
            val codec = video ?: throw IllegalStateException("not started")
            try {
                if (surface != null) {
                    codec.signalEndOfInputStream()
                } else {
                    var index = codec.dequeueInputBuffer(TIMEOUT_US)
                    while (index < 0) {
                        drain(false)
                        index = codec.dequeueInputBuffer(TIMEOUT_US)
                    }
                    codec.queueInputBuffer(index, 0, 0, frames * 1_000_000L / fps, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                }
                drain(true)
                if (!muxing) throw IllegalStateException("the encoder wrote no video")
                muxer?.stop()
            } catch (e: Exception) {
                cancel()
                throw e
            }
            release()
        }

        fun cancel() {
            release()
            File(outputPath).delete()
        }

        private fun release() {
            try { video?.stop() } catch (e: Exception) {}
            try { video?.release() } catch (e: Exception) {}
            try { muxer?.release() } catch (e: Exception) {}
            egl?.release()
            egl = null
            surface?.release()
            surface = null
            video = null
            muxer = null
            audioSamples = null
        }

        /** Moves encoded video to the muxer; at the end, until the codec says it is done. */
        private fun drain(end: Boolean) {
            val codec = video ?: return
            var idle = 0
            while (true) {
                // Mid-stream, take what is ready and go (waiting 10 ms a frame for output not there yet cost a
                // second of every 100 frames); at the end, wait for the rest.
                val out = codec.dequeueOutputBuffer(info, if (end) TIMEOUT_US else 0L)
                when {
                    out == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        if (!end || ++idle > 500) return // 5 s with nothing at the end: give up waiting
                    }
                    out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> startMuxer(codec.outputFormat)
                    out >= 0 -> {
                        idle = 0
                        val buffer = codec.getOutputBuffer(out)
                        if (buffer != null && info.size > 0 && (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                            if (!muxing) throw IllegalStateException("video before its format")
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            muxer!!.writeSampleData(videoTrack, buffer, info)
                        }
                        codec.releaseOutputBuffer(out, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
                    }
                }
            }
        }

        /** The muxer needs every track before it starts: the video's format arrives with its first output. */
        private fun startMuxer(videoFormat: MediaFormat) {
            if (muxing) return
            val m = muxer ?: return
            videoTrack = m.addTrack(videoFormat)
            val af = audioFormat
            if (af != null) audioTrack = m.addTrack(af)
            m.start()
            muxing = true
            val samples = audioSamples ?: return
            if (audioTrack >= 0) {
                for ((bytes, bi) in samples) m.writeSampleData(audioTrack, ByteBuffer.wrap(bytes), bi)
            }
            audioSamples = null
        }

        /** The WAV (16-bit PCM) to AAC-LC samples in memory, with the format the muxer needs. */
        private fun encodeAudio() {
            val raf = RandomAccessFile(audioPath, "r")
            try {
                val wav = readWav(raf) ?: throw IllegalArgumentException("the audio is not a 16-bit PCM WAV")
                val format = MediaFormat.createAudioFormat(AAC, wav.rate, wav.channels).apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_BIT_RATE, 160_000)
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
                }
                val enc = MediaCodec.createEncoderByType(AAC)
                try {
                    enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                    enc.start()
                    val frameBytes = wav.channels * 2
                    var remaining = wav.dataBytes - wav.dataBytes % frameBytes
                    var framesIn = 0L
                    var inputDone = false
                    val chunk = ByteArray(16384)
                    val bi = MediaCodec.BufferInfo()
                    raf.seek(wav.dataOffset)
                    while (true) {
                        if (!inputDone) {
                            val i = enc.dequeueInputBuffer(TIMEOUT_US)
                            if (i >= 0) {
                                val buf = enc.getInputBuffer(i)!!
                                buf.clear()
                                var n = minOf(buf.remaining().toLong(), chunk.size.toLong(), remaining).toInt()
                                n -= n % frameBytes
                                val pts = framesIn * 1_000_000L / wav.rate
                                if (n <= 0) {
                                    enc.queueInputBuffer(i, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                    inputDone = true
                                } else {
                                    raf.readFully(chunk, 0, n)
                                    buf.put(chunk, 0, n)
                                    enc.queueInputBuffer(i, 0, n, pts, 0)
                                    remaining -= n
                                    framesIn += n / frameBytes
                                }
                            }
                        }
                        val o = enc.dequeueOutputBuffer(bi, TIMEOUT_US)
                        if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                            audioFormat = enc.outputFormat
                        } else if (o >= 0) {
                            val buf = enc.getOutputBuffer(o)
                            if (buf != null && bi.size > 0 && (bi.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                                val bytes = ByteArray(bi.size)
                                buf.position(bi.offset)
                                buf.get(bytes, 0, bi.size)
                                val copy = MediaCodec.BufferInfo()
                                copy.set(0, bi.size, bi.presentationTimeUs, bi.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM.inv())
                                audioSamples?.add(Pair(bytes, copy))
                            }
                            enc.releaseOutputBuffer(o, false)
                            if ((bi.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
                        }
                    }
                } finally {
                    try { enc.stop() } catch (e: Exception) {}
                    enc.release()
                }
            } finally {
                raf.close()
            }
        }
    }

}

/**
 * An EGL context (GLES 2) on a codec's input Surface, current on the thread that made it (the encoder's one worker,
 * where every call to it runs). [draw] uploads a width × height RGBA frame (top row first) into a texture, draws it
 * over the whole surface and posts it with its presentation time.
 */
private class EglInput(surface: Surface, private val width: Int, private val height: Int) {
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var program = 0
    private var texture = 0
    private var position = 0
    private var texCoord = 0

    // A strip over the whole frame; the texture's first row (the frame's top) at the top (clip y = +1).
    private val quad: FloatBuffer = floats(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
    private val uv: FloatBuffer = floats(0f, 1f, 1f, 1f, 0f, 0f, 1f, 0f)

    init {
        try {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (display == EGL14.EGL_NO_DISPLAY) throw IllegalStateException("no EGL display")
            val version = IntArray(2)
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) eglFail("eglInitialize")
            val attribs = intArrayOf(
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGLExt.EGL_RECORDABLE_ANDROID, 1,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val count = IntArray(1)
            if (!EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, count, 0) || count[0] < 1) {
                eglFail("eglChooseConfig")
            }
            val config = configs[0]!!
            context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
            if (context == EGL14.EGL_NO_CONTEXT) eglFail("eglCreateContext")
            eglSurface = EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
            if (eglSurface == EGL14.EGL_NO_SURFACE) eglFail("eglCreateWindowSurface")
            if (!EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) eglFail("eglMakeCurrent")

            val max = IntArray(1)
            GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, max, 0)
            if (max[0] < maxOf(width, height)) throw IllegalStateException("textures here are at most ${max[0]} px")
            program = link(
                """
                attribute vec4 aPosition;
                attribute vec2 aTexCoord;
                varying vec2 vTexCoord;
                void main() { gl_Position = aPosition; vTexCoord = aTexCoord; }
                """.trimIndent(),
                """
                precision mediump float;
                varying vec2 vTexCoord;
                uniform sampler2D uFrame;
                void main() { gl_FragColor = vec4(texture2D(uFrame, vTexCoord).rgb, 1.0); }
                """.trimIndent(),
            )
            position = GLES20.glGetAttribLocation(program, "aPosition")
            texCoord = GLES20.glGetAttribLocation(program, "aTexCoord")
            val t = IntArray(1)
            GLES20.glGenTextures(1, t, 0)
            texture = t[0]
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
            // One texel to one pixel: no filtering or mipmaps (so any size works in GLES 2).
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 4)
            GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, width, height, 0, GLES20.GL_RGBA,
                GLES20.GL_UNSIGNED_BYTE, null)
            GLES20.glUseProgram(program)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uFrame"), 0)
            GLES20.glViewport(0, 0, width, height)
            GLES20.glDisable(GLES20.GL_BLEND)
            glCheck("setup")
        } catch (e: Exception) {
            release()
            throw e
        }
    }

    /** [rgba] (width × height × 4 bytes) onto the surface, presented at [ptsNs] nanoseconds. */
    fun draw(rgba: ByteBuffer, ptsNs: Long) {
        rgba.rewind()
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
        GLES20.glTexSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, width, height, GLES20.GL_RGBA,
            GLES20.GL_UNSIGNED_BYTE, rgba)
        GLES20.glUseProgram(program)
        GLES20.glEnableVertexAttribArray(position)
        GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 0, quad)
        GLES20.glEnableVertexAttribArray(texCoord)
        GLES20.glVertexAttribPointer(texCoord, 2, GLES20.GL_FLOAT, false, 0, uv)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        glCheck("draw")
        if (!EGLExt.eglPresentationTimeANDROID(display, eglSurface, ptsNs)) eglFail("eglPresentationTimeANDROID")
        if (!EGL14.eglSwapBuffers(display, eglSurface)) eglFail("eglSwapBuffers")
    }

    /** Lets the context and its window surface go. The display is left initialised: it is the process's default
     * one, which Flutter's own rendering also uses. */
    fun release() {
        if (display == EGL14.EGL_NO_DISPLAY) return
        if (context != EGL14.EGL_NO_CONTEXT && eglSurface != EGL14.EGL_NO_SURFACE &&
            EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) {
            if (texture != 0) GLES20.glDeleteTextures(1, intArrayOf(texture), 0)
            if (program != 0) GLES20.glDeleteProgram(program)
        }
        texture = 0
        program = 0
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, eglSurface)
        if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
        EGL14.eglReleaseThread()
        eglSurface = EGL14.EGL_NO_SURFACE
        context = EGL14.EGL_NO_CONTEXT
        display = EGL14.EGL_NO_DISPLAY
    }

    private fun link(vertex: String, fragment: String): Int {
        val vs = compile(GLES20.GL_VERTEX_SHADER, vertex)
        val fs = compile(GLES20.GL_FRAGMENT_SHADER, fragment)
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, vs)
        GLES20.glAttachShader(p, fs)
        GLES20.glLinkProgram(p)
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        val ok = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
        if (ok[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(p)
            GLES20.glDeleteProgram(p)
            throw IllegalStateException("the frame shader didn't link: $log")
        }
        return p
    }

    private fun compile(type: Int, source: String): Int {
        val sh = GLES20.glCreateShader(type)
        GLES20.glShaderSource(sh, source)
        GLES20.glCompileShader(sh)
        val ok = IntArray(1)
        GLES20.glGetShaderiv(sh, GLES20.GL_COMPILE_STATUS, ok, 0)
        if (ok[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(sh)
            GLES20.glDeleteShader(sh)
            throw IllegalStateException("the frame shader didn't compile: $log")
        }
        return sh
    }

    private fun glCheck(what: String) {
        val e = GLES20.glGetError()
        if (e != GLES20.GL_NO_ERROR) throw IllegalStateException("GL error 0x${Integer.toHexString(e)} in $what")
    }

    private fun eglFail(what: String): Nothing =
        throw IllegalStateException("$what failed (EGL 0x${Integer.toHexString(EGL14.eglGetError())})")

    private companion object {
        fun floats(vararg v: Float): FloatBuffer =
            ByteBuffer.allocateDirect(v.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
                put(v)
                position(0)
            }
    }
}

/** A 16-bit PCM WAV's rate, channels and where its samples are. */
private class Wav(val rate: Int, val channels: Int, val dataOffset: Long, val dataBytes: Long)

/** The `fmt ` and `data` chunks of a 16-bit PCM WAV (format 1, or WAVE_FORMAT_EXTENSIBLE with PCM); null otherwise. */
private fun readWav(raf: RandomAccessFile): Wav? {
    val head = ByteArray(12)
    raf.seek(0)
    if (raf.read(head) < 12) return null
    if (String(head, 0, 4, Charsets.US_ASCII) != "RIFF" || String(head, 8, 4, Charsets.US_ASCII) != "WAVE") return null
    var pos = 12L
    var rate = 0
    var channels = 0
    var bits = 0
    var format = 0
    val h = ByteArray(8)
    while (pos + 8 <= raf.length()) {
        raf.seek(pos)
        raf.readFully(h)
        val id = String(h, 0, 4, Charsets.US_ASCII)
        val size = ByteBuffer.wrap(h, 4, 4).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xffffffffL
        if (id == "fmt ") {
            val f = ByteArray(minOf(size, 40L).toInt())
            raf.readFully(f)
            val b = ByteBuffer.wrap(f).order(ByteOrder.LITTLE_ENDIAN)
            format = b.getShort(0).toInt() and 0xffff
            channels = b.getShort(2).toInt() and 0xffff
            rate = b.getInt(4)
            bits = b.getShort(14).toInt() and 0xffff
            if (format == 0xFFFE && f.size >= 26) format = b.getShort(24).toInt() and 0xffff
        } else if (id == "data") {
            if (format != 1 || bits != 16 || channels !in 1..2 || rate <= 0) return null
            return Wav(rate, channels, pos + 8, minOf(size, raf.length() - pos - 8))
        }
        pos += 8 + size + (size and 1L)
    }
    return null
}
