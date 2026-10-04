// mob_video plugin — Android bridge (MediaExtractor / MediaMuxer /
// MediaMetadataRetriever). Lives in the plugin's own package; mob_dev copies it
// into the app Kotlin sourceSet and MobPluginBootstrap.registerAll() calls
// register() at startup. No Activity/permission handoff needed — every op works
// on plain file paths.
//
// The native thunks (nativeRegister + the nativeDeliver* hooks) are exported
// directly from the sibling zig NIF mob_video_nif.zig. All work runs on a
// single-thread worker so the BEAM scheduler thread that called the NIF never
// blocks; results are delivered back by pid.
//
// Error codes (nativeDeliverVideoError): 0 not_found, 1 unsupported,
// 2 io_error, 3 bad_range.
package io.mob.video

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors

object MobVideoBridge {
    private val worker = Executors.newSingleThreadExecutor()

    private const val ERR_NOT_FOUND = 0
    private const val ERR_UNSUPPORTED = 1
    private const val ERR_IO = 2
    private const val ERR_BAD_RANGE = 3

    @JvmStatic external fun nativeRegister()

    @JvmStatic external fun nativeDeliverVideoInfo(
        pid: Long,
        durationMs: Long,
        width: Int,
        height: Int,
        rotation: Int,
        hasAudio: Int,
        bitrate: Long,
        frameRate: Double,
    )

    @JvmStatic external fun nativeDeliverClipped(pid: Long, path: String, durationMs: Long)

    @JvmStatic external fun nativeDeliverThumbnail(pid: Long, path: String, width: Int, height: Int)

    @JvmStatic external fun nativeDeliverAudio(pid: Long, path: String)

    @JvmStatic external fun nativeDeliverVideoError(pid: Long, code: Int)

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    // ── Probe ────────────────────────────────────────────────────────────
    @JvmStatic
    fun video_probe(pid: Long, src: String) = worker.execute {
        if (!File(src).exists()) {
            nativeDeliverVideoError(pid, ERR_NOT_FOUND); return@execute
        }
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(src)
            val duration = r.meta(MediaMetadataRetriever.METADATA_KEY_DURATION)
            val width = r.meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            val height = r.meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            if (width == 0L || height == 0L) {
                nativeDeliverVideoError(pid, ERR_UNSUPPORTED); return@execute
            }
            val rotation = r.meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
            val bitrate = r.meta(MediaMetadataRetriever.METADATA_KEY_BITRATE)
            val hasAudio = r.metaStr(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
            val frameCount = r.meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)
            val fps = if (frameCount > 0 && duration > 0) frameCount * 1000.0 / duration else 0.0
            nativeDeliverVideoInfo(
                pid, duration, width.toInt(), height.toInt(), rotation.toInt(),
                if (hasAudio) 1 else 0, bitrate, fps,
            )
        } catch (e: Exception) {
            nativeDeliverVideoError(pid, ERR_UNSUPPORTED)
        } finally {
            r.release()
        }
    }

    // ── Clip (stream copy, no re-encode) ──────────────────────────────────
    @JvmStatic
    fun video_clip(pid: Long, src: String, dst: String, startMs: Long, endMs: Long) = worker.execute {
        if (!File(src).exists()) {
            nativeDeliverVideoError(pid, ERR_NOT_FOUND); return@execute
        }
        // A positive end that isn't after the start is an empty/inverted range.
        if (endMs in 1..startMs) {
            nativeDeliverVideoError(pid, ERR_BAD_RANGE); return@execute
        }
        remux(pid, src, dst, startMs, endMs, audioOnly = false)
    }

    // ── Extract audio (stream copy of the audio track) ────────────────────
    @JvmStatic
    fun video_extract_audio(pid: Long, src: String, dst: String) = worker.execute {
        if (!File(src).exists()) {
            nativeDeliverVideoError(pid, ERR_NOT_FOUND); return@execute
        }
        remux(pid, src, dst, 0, 0, audioOnly = true)
    }

    // ── Thumbnail (single decoded frame -> JPEG) ──────────────────────────
    @JvmStatic
    fun video_thumbnail(pid: Long, src: String, dst: String, atMs: Long, maxWidth: Long) = worker.execute {
        if (!File(src).exists()) {
            nativeDeliverVideoError(pid, ERR_NOT_FOUND); return@execute
        }
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(src)
            var bmp: Bitmap = r.getFrameAtTime(atMs * 1000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: run { nativeDeliverVideoError(pid, ERR_UNSUPPORTED); return@execute }
            if (maxWidth > 0) bmp = scaleToFit(bmp, maxWidth.toInt())
            FileOutputStream(dst).use { bmp.compress(Bitmap.CompressFormat.JPEG, 90, it) }
            nativeDeliverThumbnail(pid, dst, bmp.width, bmp.height)
        } catch (e: Exception) {
            nativeDeliverVideoError(pid, ERR_IO)
        } finally {
            r.release()
        }
    }

    // ── Shared remux: select tracks, optionally bound to [startUs, endUs) ──
    private fun remux(pid: Long, src: String, dst: String, startMs: Long, endMs: Long, audioOnly: Boolean) {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            extractor.setDataSource(src)
            muxer = MediaMuxer(dst, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val indexMap = HashMap<Int, Int>()
            var maxBuf = 0
            for (t in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(t)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                val keep = if (audioOnly) mime.startsWith("audio/") else mime.startsWith("video/") || mime.startsWith("audio/")
                if (!keep) continue
                extractor.selectTrack(t)
                indexMap[t] = muxer.addTrack(format)
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    maxBuf = maxOf(maxBuf, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                }
            }
            if (indexMap.isEmpty()) {
                nativeDeliverVideoError(pid, ERR_UNSUPPORTED); return
            }
            if (maxBuf <= 0) maxBuf = 1 shl 20
            applyOrientation(src, muxer)
            muxer.start()

            val startUs = startMs * 1000
            val endUs = if (endMs > 0) endMs * 1000 else Long.MAX_VALUE
            if (startUs > 0) extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            val buffer = ByteBuffer.allocate(maxBuf)
            val info = MediaCodec.BufferInfo()
            var firstUs = -1L
            var lastUs = 0L
            while (true) {
                val sampleTime = extractor.sampleTime
                if (sampleTime < 0) break
                if (sampleTime > endUs) break
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                if (firstUs < 0) firstUs = sampleTime
                lastUs = sampleTime
                info.offset = 0
                info.size = size
                info.presentationTimeUs = sampleTime
                info.flags = if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
                    MediaCodec.BUFFER_FLAG_KEY_FRAME
                } else {
                    0
                }
                indexMap[extractor.sampleTrackIndex]?.let { muxer.writeSampleData(it, buffer, info) }
                extractor.advance()
            }
            muxer.stop()
            val durationMs = if (firstUs in 0..lastUs) (lastUs - firstUs) / 1000 else 0
            if (audioOnly) nativeDeliverAudio(pid, dst) else nativeDeliverClipped(pid, dst, durationMs)
        } catch (e: IllegalArgumentException) {
            // setDataSource / addTrack reject -> unreadable or unsupported container.
            nativeDeliverVideoError(pid, ERR_UNSUPPORTED)
        } catch (e: Exception) {
            nativeDeliverVideoError(pid, ERR_IO)
        } finally {
            runCatching { muxer?.release() }
            runCatching { extractor.release() }
        }
    }

    private fun applyOrientation(src: String, muxer: MediaMuxer) {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(src)
            val rot = r.meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION).toInt()
            if (rot != 0) muxer.setOrientationHint(rot)
        } catch (e: Exception) {
            // Orientation is a hint; a missing value is harmless.
        } finally {
            r.release()
        }
    }

    private fun scaleToFit(bmp: Bitmap, maxSide: Int): Bitmap {
        val longest = maxOf(bmp.width, bmp.height)
        if (longest <= maxSide) return bmp
        val scale = maxSide.toFloat() / longest
        val w = (bmp.width * scale).toInt().coerceAtLeast(1)
        val h = (bmp.height * scale).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(bmp, w, h, true)
    }

    private fun MediaMetadataRetriever.meta(key: Int): Long =
        extractMetadata(key)?.toLongOrNull() ?: 0L

    private fun MediaMetadataRetriever.metaStr(key: Int): String? = extractMetadata(key)
}
