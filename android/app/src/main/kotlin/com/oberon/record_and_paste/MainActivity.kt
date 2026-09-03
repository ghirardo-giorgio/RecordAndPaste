package com.oberon.record_and_paste

import android.content.Context
import android.media.AudioManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Silenzia i segnali acustici del riconoscimento vocale mentre l'app aspetta
 * la frase di attivazione.
 *
 * Android li fa suonare a ogni sessione di ascolto, non a ogni dettatura, e la
 * sessione viene chiusa e riaperta dal sistema anche quando nessuno parla:
 * senza questo, chi tiene acceso l'ascolto sente trillare il telefono in
 * continuazione senza aver detto niente. Non esiste un modo ufficiale di
 * chiedere al riconoscitore di stare zitto, quindi si mettono in muto gli
 * stream su cui quei suoni finiscono.
 *
 * Si ripristina sempre quello che si e' mutato, e solo quello: se un flusso
 * era gia' muto perche' l'utente lo aveva silenziato, non va riacceso.
 */
class MainActivity : FlutterActivity() {
    private val channel = "record_and_paste/system_sounds"

    /** Stream messi in muto da noi, da ripristinare. */
    private val muted = mutableSetOf<Int>()

    /**
     * I suoni del riconoscimento non finiscono sempre sullo stesso stream: il
     * servizio Google usa "assistance sonification", che i produttori mappano
     * ora su SYSTEM ora su MUSIC. Si coprono tutti quelli plausibili.
     */
    private val streams = listOf(
        AudioManager.STREAM_SYSTEM,
        AudioManager.STREAM_NOTIFICATION,
        AudioManager.STREAM_MUSIC,
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "mute" -> {
                        setMuted(true)
                        result.success(null)
                    }
                    "unmute" -> {
                        setMuted(false)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * L'app non deve poter lasciare il telefono muto: se viene chiusa mentre
     * l'ascolto e' attivo, si ripristina comunque.
     */
    override fun onDestroy() {
        setMuted(false)
        super.onDestroy()
    }

    private fun setMuted(mute: Boolean) {
        val audio = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return

        if (mute) {
            for (stream in streams) {
                if (stream in muted) continue
                try {
                    // gia' muto per scelta dell'utente: non e' roba nostra,
                    // non va toccata (ne' riaccesa dopo)
                    if (audio.isStreamMute(stream)) continue
                    audio.adjustStreamVolume(
                        stream, AudioManager.ADJUST_MUTE, 0)
                    muted.add(stream)
                } catch (_: SecurityException) {
                    // con "Non disturbare" attivo il sistema puo' rifiutare di
                    // toccare alcuni stream: gli altri si silenziano lo stesso
                }
            }
        } else {
            for (stream in muted.toList()) {
                try {
                    audio.adjustStreamVolume(
                        stream, AudioManager.ADJUST_UNMUTE, 0)
                } catch (_: SecurityException) {
                }
            }
            muted.clear()
        }
    }
}
