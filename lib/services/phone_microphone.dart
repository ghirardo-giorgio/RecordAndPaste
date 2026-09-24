import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// Formato dell'audio spedito al PC: e' lo stesso che il demone registrerebbe
/// da se' con pw-record (mono, 16 kHz, 16 bit con segno), cosi' il file che ne
/// esce e' indistinguibile da quello di una dettatura normale e tutto quello
/// che viene dopo — controllo del silenzio, trascrizione, vocabolario — resta
/// com'era.
const _sampleRate = 16000;
const _bytesPerSample = 2;

/// Quanto audio si accumula prima di spedirlo: un decimo di secondo.
///
/// Il plugin consegna frammenti di dimensione variabile, e mandarli cosi' come
/// arrivano vorrebbe dire un numero imprevedibile di messaggi al secondo,
/// ognuno con l'intestazione JSON e la codifica base64 addosso. Cosi' si resta
/// su una decina di messaggi al secondo (circa 43 KB/s), e il ritardo aggiunto
/// non si sente: quando l'utente ferma la dettatura l'audio e' gia' quasi
/// tutto sul PC.
const chunkBytes = _sampleRate * _bytesPerSample ~/ 10;

/// Raccoglie i frammenti che arrivano dal microfono e li ritaglia in blocchi
/// di dimensione fissa.
///
/// Sta fuori da [PhoneMicrophone] per poter essere provata senza microfono:
/// e' l'unico pezzo con una logica che possa sbagliare.
class AudioChunker {
  AudioChunker(this.size, this.onChunk);

  final int size;
  final void Function(Uint8List chunk) onChunk;
  final BytesBuilder _pending = BytesBuilder(copy: false);

  /// Byte arrivati ma non ancora consegnati.
  int get pending => _pending.length;

  void add(Uint8List data) {
    _pending.add(data);
    while (_pending.length >= size) {
      // takeBytes svuota il buffer, quindi l'eccedenza va rimessa dentro: un
      // frammento del plugin puo' valere piu' blocchi
      final bytes = _pending.takeBytes();
      onChunk(Uint8List.sublistView(bytes, 0, size));
      if (bytes.length > size) {
        _pending.add(Uint8List.sublistView(bytes, size));
      }
    }
  }

  /// Consegna anche l'ultimo blocco, incompleto: e' il pezzo di frase che
  /// l'utente ha appena finito di dire, e buttarlo troncherebbe la dettatura.
  void flush() {
    if (_pending.length > 0) onChunk(_pending.takeBytes());
  }

  void clear() => _pending.clear();
}

/// Registra col microfono del telefono e consegna l'audio a blocchi, perche'
/// sia il PC a trascriverlo.
///
/// Serve quando il microfono del PC non e' utilizzabile — occupato da un'altra
/// applicazione — ma la trascrizione conviene comunque lasciarla li', dove c'e'
/// la scheda grafica. E' l'opposto della raccolta di testo del
/// WakeWordService: qui il telefono non capisce niente di quello che sente, si
/// limita a portarlo dall'altra parte.
///
/// Il microfono e' uno solo: mentre questo servizio registra, l'ascolto della
/// frase di attivazione va tenuto fermo (vedi HomeScreen).
class PhoneMicrophone extends ChangeNotifier {
  PhoneMicrophone({AudioRecorder? recorder}) : _recorder = recorder;

  /// Creato alla prima registrazione, non nel costruttore: costruire un
  /// AudioRecorder apre subito il canale verso il plugin nativo, e chi non
  /// usa mai questa modalita' (o gira dentro un test) non ha motivo di
  /// pagarlo.
  AudioRecorder? _recorder;
  AudioRecorder get _mic => _recorder ??= AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  AudioChunker? _chunker;

  bool _recording = false;
  bool get recording => _recording;

  /// Perche' l'ultimo tentativo non e' partito: permesso negato, microfono
  /// occupato da un'altra app del telefono, plugin non disponibile. Va
  /// mostrato, altrimenti il pulsante sembra soltanto non funzionare.
  String? lastError;

  /// Dove vanno i blocchi di audio, uno ogni decimo di secondo circa.
  void Function(Uint8List pcm)? onChunk;

  /// Apre il microfono. Torna false se non ci si e' riusciti: in quel caso
  /// [lastError] dice perche', e la dettatura non deve partire.
  Future<bool> start() async {
    if (_recording) return true;
    lastError = null;
    try {
      if (!await _mic.hasPermission()) {
        lastError = 'permesso del microfono negato';
        notifyListeners();
        return false;
      }
      final stream = await _mic.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: 1,
          // il telefono e' spesso lontano da chi parla: senza guadagno
          // automatico le dettature a mezzo metro arrivano al PC cosi' deboli
          // che il rilevatore di voce non le distingue dal silenzio, e la
          // dettatura si chiuderebbe da sola mentre l'utente sta parlando
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        ),
      );
      _chunker = AudioChunker(chunkBytes, (chunk) => onChunk?.call(chunk));
      _recording = true;
      _sub = stream.listen(
        (data) {
          if (_recording) _chunker?.add(data);
        },
        onError: (Object error) {
          lastError = error.toString();
          notifyListeners();
        },
      );
    } catch (e) {
      lastError = e.toString();
      _recording = false;
      notifyListeners();
      return false;
    }
    notifyListeners();
    return true;
  }

  /// Chiude il microfono, spedendo prima quello che era rimasto nel buffer.
  Future<void> stop() async {
    if (!_recording) return;
    _recording = false;
    await _sub?.cancel();
    _sub = null;
    try {
      await _mic.stop();
    } catch (_) {
      // se il microfono era gia' chiuso non c'e' niente da fare: quello che
      // conta e' che questo servizio si consideri fermo
    }
    _chunker?.flush();
    _chunker = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    // se non ha mai registrato non c'e' nessun canale nativo da chiudere
    _recorder?.dispose();
    super.dispose();
  }
}
