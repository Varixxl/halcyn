package io.github.varixxl.halcyn

import java.net.HttpURLConnection
import java.net.URL
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.MediaFormat
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.stream.DeliveryMethod
import org.schabi.newpipe.extractor.stream.StreamInfo

/** A YouTube Music song's audio address, found by NewPipe's extractor (what yt-dlp does
 *  on a computer): Premium's 256 kbps AAC when it's offered, else Opus, else AAC. */
object YouTubeAudio {
    private const val AGENT = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
    private var started = false

    private object Net : Downloader() {
        override fun execute(request: Request): Response {
            val connection = URL(request.url()).openConnection() as HttpURLConnection
            connection.requestMethod = request.httpMethod()
            connection.connectTimeout = 15000
            connection.readTimeout = 30000
            for ((key, values) in request.headers()) {
                values.forEach { connection.addRequestProperty(key, it) }
            }
            if (request.headers().keys.none { it.equals("User-Agent", true) }) {
                connection.setRequestProperty("User-Agent", AGENT)
            }
            request.dataToSend()?.let {
                connection.doOutput = true
                connection.outputStream.use { out -> out.write(it) }
            }
            val code = connection.responseCode
            val body = (if (code >= 400) connection.errorStream else connection.inputStream)
                ?.use { it.readBytes().toString(Charsets.UTF_8) }
            val headers = connection.headerFields.filterKeys { it != null }
            return Response(code, connection.responseMessage, headers, body, connection.url.toString())
        }
    }

    /** (blocking) The address of video [id]'s best audio. */
    fun find(id: String): String {
        synchronized(this) {
            if (!started) {
                NewPipe.init(Net)
                started = true
            }
        }
        val info = StreamInfo.getInfo(ServiceList.YouTube, "https://www.youtube.com/watch?v=$id")
        val streams = info.audioStreams
            .filter { it.deliveryMethod == DeliveryMethod.PROGRESSIVE_HTTP && it.content.isNotEmpty() }
        val aac = streams.filter { it.format == MediaFormat.M4A }.maxByOrNull { it.averageBitrate }
        val opus = streams.filter { it.format == MediaFormat.WEBMA_OPUS }.maxByOrNull { it.averageBitrate }
        // averageBitrate is in kbps (-1 when unknown).
        val audio = (if (aac != null && aac.averageBitrate >= 200) aac else null)
            ?: opus ?: aac ?: error("YouTube has no audio of it Halcyn can play")
        return audio.content
    }
}
