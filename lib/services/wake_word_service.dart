import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'system_sounds.dart';
import 'wake_phrase.dart';

/// Perche' l'ascolto non parte con [listen] una volta sola: il riconoscitore
/// di Android chiude la sessione da solo, e il servizio deve riaprirla.
///
/// Ogni riapertura fa suonare il segnale acustico di sistema, quindi il numero
/// di sessioni si sente: le sessioni vanno tenute lunghe e le riaperture
/// distanziate. Con una sessione che si chiudeva dopo cinque secondi di
/// silenzio erano una ventina di trilli al minuto — la dettatura non era
/// ancora partita e sembrava che l'app suonasse a vuoto.
const _restartDelay = Duration(seconds: 2);

/// Quanto si chiede al riconoscitore di restare in ascolto. Android non
/// garantisce di rispettarlo fino in fondo, ma piu' e' lungo, meno spesso la
/// sessione si chiude — e meno trilli si sentono.
const _sessionDuration = Duration(minutes: 10);

/// Dopo un riconoscimento si smette di ascoltare per un momento: la frase
/// resta nel risultato parziale ancora per un po' e verrebbe riconosciuta due
/// volte. Stesso ruolo di WAKE_COOLDOWN_SECONDS in daemon.py.
const _cooldown = Duration(milliseconds: 2500);

/// Ascolta il microfono del telefono e segnala quando sente una delle due
/// frasi di attivazione, cosi' la dettatura si avvia e si ferma senza toccare
/// il pulsante.
///
/// Riconosce solo le frasi: il testo dettato non passa mai di qui, continua a
/// essere registrato e trascritto dal PC. E' l'ascolto "gemello" di quello del
/// demone (WakeWordListener in daemon.py) e usa le stesse due frasi, che
/// arrivano dalla configurazione del demone.
///
/// Funziona con l'app in primo piano, che e' anche l'unico momento in cui lo
/// schermo resta acceso (vedi il wakelock in HomeScreen).
class WakeWordService extends ChangeNotifier {
  WakeWordService({SpeechToText? speech}) : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;

  /// Le due frasi da riconoscere e la lingua, riletti a ogni sessione: se
  /// l'utente li cambia nelle impostazioni l'effetto e' immediato.
  String Function() startPhrase = () => 'jarvis';
  String Function() stopPhrase = () => 'jarvis stop';
  String Function() localeId = () => 'it_IT';

  /// Cosa fare quando una frase viene riconosciuta. Chi le riceve decide se
  /// sono pertinenti: [onStart] arriva anche se la dettatura e' gia' in corso.
  VoidCallback? onStart;
  VoidCallback? onStop;

  /// Se la dettatura e' gia' in corso: in quel momento il microfono del
  /// telefono sente anche quello che si sta dettando, quindi si cerca solo la
  /// frase di stop e solo in fondo a quello che e' stato sentito.
  bool Function() dictationInProgress = () => false;

  /// Ultima frase sentita dal riconoscitore e ultima che ha fatto scattare
  /// l'attivazione. Servono a capire perche' l'attivazione parte quando non
  /// dovrebbe (o non parte): il riconoscitore scrive in italiano parole
  /// inventate in un'altra lingua, e senza vederle non c'e' modo di indovinare
  /// quali varianti configurare.
  String lastHeard = '';
  String lastTriggered = '';

  /// Testo raccolto mentre e' il telefono a trascrivere la dettatura (vedi
  /// [startCollecting]). Le sessioni di riconoscimento possono chiudersi a
  /// meta' dettatura, quindi il testo gia' consegnato va tenuto da parte:
  /// [_collectedBase] e' quello delle sessioni chiuse, a cui si aggiunge
  /// quello della sessione in corso.
  bool _collecting = false;
  String _collectedBase = '';
  String _collectedCurrent = '';

  /// Se il telefono sta raccogliendo il testo della dettatura.
  bool get collecting => _collecting;

  /// Quello che si e' sentito finora in questa dettatura.
  String get collectedText =>
      [_collectedBase, _collectedCurrent]
          .where((p) => p.trim().isNotEmpty)
          .join(' ')
          .trim();

  /// Se silenziare i segnali acustici del riconoscimento mentre si aspetta la
  /// frase. Vengono ripristinati durante la dettatura vera, cosi' l'inizio e
  /// la fine restano udibili: sono gli unici momenti in cui dicono qualcosa.
  bool silenceBeeps = true;

  bool _enabled = false;
  bool _listening = false;
  bool _initialized = false;
  bool _unavailable = false;
  bool _dictating = false;
  DateTime _mutedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _restartTimer;

  /// Se il servizio sta ascoltando davvero (non basta che sia acceso: puo'
  /// essere in pausa fra una sessione e l'altra).
  bool get listening => _listening;

  /// Se l'utente l'ha acceso.
  bool get enabled => _enabled;

  /// Se il telefono non puo' ascoltare: permesso negato, oppure nessun
  /// riconoscimento vocale disponibile. Serve a spiegarlo nelle impostazioni
  /// invece di lasciare un interruttore acceso che non fa nulla.
  bool get unavailable => _unavailable;

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    if (value) {
      await _applySilence();
      await _startListening();
    } else {
      await _stopListening();
      await SystemSounds.unmute();
    }
  }

  /// Va chiamato quando la dettatura sul PC parte o finisce: durante la
  /// dettatura i segnali acustici tornano udibili, perche' e' il momento in
  /// cui servono davvero a capire cosa sta succedendo.
  Future<void> setDictating(bool value) async {
    if (_dictating == value) return;
    _dictating = value;
    await _applySilence();
  }

  /// Comincia a raccogliere il testo della dettatura, riaprendo la sessione
  /// di riconoscimento: cosi' quello che era stato sentito prima non finisce
  /// nel testo da incollare.
  Future<void> startCollecting() async {
    _collecting = true;
    _collectedBase = '';
    _collectedCurrent = '';
    // i segnali acustici tornano udibili: qui la dettatura sta partendo
    // davvero, ed e' il momento in cui servono
    await setDictating(true);
    if (!await _ensureReady()) return;
    await _stopListening();
    await _startListening();
  }

  /// Chiude la raccolta e restituisce il testo sentito.
  Future<String> stopCollecting() async {
    final testo = collectedText;
    _collecting = false;
    _collectedBase = '';
    _collectedCurrent = '';
    await setDictating(false);
    if (_enabled) {
      // si torna in ascolto della frase di avvio; se l'ascolto era spento la
      // sessione si chiude e basta
      await _stopListening();
      _scheduleRestart();
    } else {
      await _stopListening();
    }
    return testo;
  }

  Future<void> _applySilence() async {
    final vogliamoSilenzio = _enabled && silenceBeeps && !_dictating;
    if (vogliamoSilenzio == SystemSounds.muted) return;
    if (vogliamoSilenzio) {
      await SystemSounds.mute();
    } else {
      await SystemSounds.unmute();
    }
  }

  /// Chiede il permesso del microfono e prepara il riconoscitore. Ritorna
  /// false se il telefono non puo' ascoltare, cosi' chi chiama puo' dirlo
  /// all'utente invece di far finta di aver acceso qualcosa.
  Future<bool> _ensureReady() async {
    if (_initialized) return !_unavailable;
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      _unavailable = true;
      _initialized = true;
      notifyListeners();
      return false;
    }
    final available = await _speech.initialize(
      onStatus: _onStatus,
      onError: (_) => _scheduleRestart(),
      // il riconoscitore continua a servire anche quando l'app perde il
      // fuoco per un istante (es. una notifica): non vale la pena spegnerlo
      finalTimeout: const Duration(milliseconds: 500),
    );
    _initialized = true;
    _unavailable = !available;
    notifyListeners();
    return available;
  }

  Future<void> _startListening() async {
    // la raccolta del testo dettato usa il riconoscitore anche quando
    // l'attivazione vocale e' spenta: li' non si aspetta nessuna frase, si
    // trascrive e basta
    if ((!_enabled && !_collecting) || _listening) return;
    if (!await _ensureReady()) return;
    if (!_enabled && !_collecting) return; // spento mentre si chiedeva il permesso
    try {
      await _speech.listen(
        onResult: _onResult,
        listenOptions: SpeechListenOptions(
          localeId: localeId(),
          // i risultati parziali fanno scattare la frase mentre l'utente sta
          // ancora parlando, invece di aspettare che la sessione si chiuda
          partialResults: true,
          // "dictation" tiene la sessione aperta durante le pause, mentre
          // "search" la chiude appena si smette di parlare. Qui le pause sono
          // la norma — si aspetta una frase che puo' arrivare fra minuti — e
          // ogni riapertura di sessione fa suonare il segnale acustico di
          // Android: con la modalita' sbagliata sono decine di trilli al
          // minuto (vedi _restartDelay).
          listenMode: ListenMode.dictation,
          cancelOnError: true,
          // niente chiusura automatica sul silenzio: la sessione va tenuta
          // aperta il piu' a lungo possibile, sempre per via dei trilli
          pauseFor: _sessionDuration,
          listenFor: _sessionDuration,
        ),
      );
      _listening = true;
      notifyListeners();
    } catch (_) {
      _scheduleRestart();
    }
  }

  Future<void> _stopListening() async {
    _restartTimer?.cancel();
    _restartTimer = null;
    _listening = false;
    try {
      await _speech.stop();
    } catch (_) {
      // il riconoscitore puo' essere gia' chiuso: non c'e' niente da fare
    }
    notifyListeners();
  }

  void _onStatus(String status) {
    // "done"/"notListening": la sessione si e' chiusa da sola, va riaperta
    if (status == 'done' || status == 'notListening') {
      _listening = false;
      if (_collecting && _collectedCurrent.trim().isNotEmpty) {
        // la sessione puo' chiudersi in mezzo a una dettatura lunga: quello
        // che aveva sentito va messo da parte, altrimenti la riapertura lo
        // farebbe ripartire da zero e il testo andrebbe perso
        _collectedBase = collectedText;
        _collectedCurrent = '';
      }
      notifyListeners();
      _scheduleRestart();
    }
  }

  void _scheduleRestart() {
    if (!_enabled && !_collecting) return;
    _restartTimer?.cancel();
    final wait = _mutedUntil.isAfter(DateTime.now())
        ? _mutedUntil.difference(DateTime.now())
        : _restartDelay;
    _restartTimer = Timer(wait, () {
      _restartTimer = null;
      _startListening();
    });
  }

  void _onResult(SpeechRecognitionResult result) {
    if (!_enabled) return;
    final heard = result.recognizedWords;
    if (heard.isEmpty) return;
    if (heard != lastHeard) {
      lastHeard = heard;
      notifyListeners();
    }
    if (_collecting) {
      // sta trascrivendo il telefono: tutto quello che sente e' testo dettato
      _collectedCurrent = heard;
    }
    if (DateTime.now().isBefore(_mutedUntil)) return;
    if (dictationInProgress()) {
      // si sta dettando: l'unica cosa che ha senso sentire e' la frase di
      // stop, e solo in fondo — in mezzo al discorso sarebbe testo dettato
      if (phraseInText(stopPhrase(), heard, onlyTail: true)) {
        _fire(onStop, heard);
      }
      return;
    }
    // sempre e solo in fondo: la sessione resta aperta a lungo (vedi
    // _sessionDuration) e quello che il riconoscitore riporta comprende tutto
    // il parlato di prima. La frase appena pronunciata e' in coda; cercarla in
    // tutto il discorso vorrebbe dire riesaminare all'infinito parole vecchie,
    // ed e' un ottimo modo per far partire la dettatura da sola.
    //
    // La frase di stop va provata per prima: contenendo di solito quella di
    // avvio ("jarvis" / "jarvis stop"), l'ordine opposto la fermerebbe sempre
    // sulla frase di avvio.
    if (phraseInText(stopPhrase(), heard, onlyTail: true)) {
      _fire(onStop, heard);
    } else if (phraseInText(startPhrase(), heard, onlyTail: true)) {
      _fire(onStart, heard);
    }
  }

  void _fire(VoidCallback? callback, String heard) {
    lastTriggered = heard;
    _mutedUntil = DateTime.now().add(_cooldown);
    // la sessione in corso ha gia' sentito la frase: si chiude e se ne apre
    // una pulita, altrimenti la stessa frase resterebbe nei risultati
    unawaited(_stopListening().then((_) => _scheduleRestart()));
    callback?.call();
  }

  @override
  void dispose() {
    _restartTimer?.cancel();
    _restartTimer = null;
    _enabled = false;
    // il telefono non va lasciato muto: e' la prima cosa da rimettere a posto
    SystemSounds.unmute();
    try {
      _speech.cancel();
    } catch (_) {
      // niente da fare se il riconoscitore e' gia' andato
    }
    super.dispose();
  }
}
