// The music video's MP4 encoder (`caw/video`): RGBA frames to H.264 with MediaCodec, a 16-bit WAV to AAC, both muxed by MediaMuxer.
package com.kmandevr.caw

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors

/**
 * Methods (all run on one worker thread, in order; replies come back on the main thread):
 * - `caps`: {maxLong, maxShort}, the largest frame the first H.264 encoder takes either way round.
 * - `start` {width, height, fps, bitrate, audio (a 16-bit PCM WAV), output}: picks an H.264 encoder that takes the
 *   size, encodes the whole audio to AAC-LC first (kept in memory: about 20 KB a second), and opens the muxer.
 * - `frame` {rgba}: one frame, width × height × 4 bytes, top row first; converted to YUV 4:2:0 (BT.601) into the
 *   codec's input Image, timed at frame / fps.
 * - `finish`: ends the stream and closes the file. `cancel`: stops and deletes the file.
 *
 * Platform APIs only, no library (Android Developers, read 2026-11-11): MediaCodec (getInputImage API 21,
 * COLOR_FormatYUV420Flexible API 21), MediaMuxer (MPEG-4 output API 18), MediaCodecList (API 21):
 * developer.android.com/reference/android/media/MediaCodec, .../MediaMuxer, .../MediaCodecList.
 */
class VideoEncoder : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var session: Session? = null

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
                    s.frame(rgba ?: throw IllegalArgumentException("no frame"))
                    null
                }
            }
            "finish" -> run(result) {
                val s = session ?: throw IllegalStateException("not started")
                session = null
                s.finish()
                null
            }
            "cancel" -> run(result) {
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

    /** One encode: the video codec, the AAC samples waiting for the muxer, and the muxer. */
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
            val codecInfo = avcEncoders().firstOrNull {
                it.getCapabilitiesForType(AVC).videoCapabilities.isSizeSupported(width, height)
            } ?: throw IllegalArgumentException("no H.264 encoder here takes ${width}x$height")
            encodeAudio()
            val format = MediaFormat.createVideoFormat(AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
            val codec = MediaCodec.createByCodecName(codecInfo.name)
            video = codec
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        }

        fun frame(rgba: ByteArray) {
            if (rgba.size != width * height * 4) throw IllegalArgumentException("frame is ${rgba.size} bytes")
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
            for (row in 0 until height) {
                val src = row * width * 4
                val dst = row * y.rowStride
                for (col in 0 until width) {
                    val p = src + col * 4
                    val r = rgba[p].toInt() and 0xff
                    val g = rgba[p + 1].toInt() and 0xff
                    val b = rgba[p + 2].toInt() and 0xff
                    yb.put(dst + col * y.pixelStride, (((66 * r + 129 * g + 25 * b + 128) shr 8) + 16).toByte())
                }
            }
            for (row in 0 until height / 2) {
                for (col in 0 until width / 2) {
                    // The average of the 2x2 block.
                    var r = 0
                    var g = 0
                    var b = 0
                    for (dy in 0..1) for (dx in 0..1) {
                        val p = ((row * 2 + dy) * width + col * 2 + dx) * 4
                        r += rgba[p].toInt() and 0xff
                        g += rgba[p + 1].toInt() and 0xff
                        b += rgba[p + 2].toInt() and 0xff
                    }
                    r = r shr 2
                    g = g shr 2
                    b = b shr 2
                    ub.put(row * u.rowStride + col * u.pixelStride, (((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128).toByte())
                    vb.put(row * v.rowStride + col * v.pixelStride, (((112 * r - 94 * g - 18 * b + 128) shr 8) + 128).toByte())
                }
            }
            val pts = frames * 1_000_000L / fps
            codec.queueInputBuffer(index, 0, width * height * 3 / 2, pts, 0)
            frames++
            drain(false)
        }

        fun finish() {
            val codec = video ?: throw IllegalStateException("not started")
            try {
                var index = codec.dequeueInputBuffer(TIMEOUT_US)
                while (index < 0) {
                    drain(false)
                    index = codec.dequeueInputBuffer(TIMEOUT_US)
                }
                codec.queueInputBuffer(index, 0, 0, frames * 1_000_000L / fps, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
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
            video = null
            muxer = null
            audioSamples = null
        }

        /** Moves encoded video to the muxer; at the end, until the codec says it is done. */
        private fun drain(end: Boolean) {
            val codec = video ?: return
            var idle = 0
            while (true) {
                val out = codec.dequeueOutputBuffer(info, TIMEOUT_US)
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
