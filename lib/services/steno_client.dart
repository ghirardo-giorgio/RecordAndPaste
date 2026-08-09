import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/button_spec.dart';
import '../models/connection_settings.dart';
import '../models/daemon_state.dart';
import 'settings_service.dart';

/// Formatta l'impronta di un certificato come "AA:BB:CC…", lo stesso
/// formato usato dal demone (vedi _cert_fingerprint in daemon.py) cosi' le
/// due stringhe si confrontano a vista.
String formatFingerprint(List<int> bytes) => bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(':');

/// Esito dell'apertura di una connessione verso il demone.
class DaemonConnection {
  const DaemonConnection(this.socket, {required this.secure, this.fingerprint});

  final Socket socket;
  final bool secure;
  final String? fingerprint;
}

/// Il certificato presentato dal PC non corrisponde a quello accettato al
/// primo collegamento: o il demone e' stato reinstallato (certificato
/// rigenerato), o qualcuno sulla stessa rete si sta spacciando per il PC.
/// In entrambi i casi la connessione non prosegue senza una scelta
/// esplicita dell'utente.
class CertificateMismatch implements Exception {
  const CertificateMismatch(this.presented);

  /// Impronta del certificato appena presentato, da mostrare all'utente
  /// accanto a quella attesa.
  final String presented;
}

/// Client TCP verso il demone Stenografa sul PC.
///
/// Protocollo: righe JSON separate da "\n". Dopo la connessione va inviato
/// per primo `{"cmd":"auth","token":"..."}`; solo dopo un `{"type":"auth",
/// "ok":true}` il demone accetta `{"cmd":"toggle"}` e comincia a inviare gli
/// aggiornamenti di stato (`{"type":"state",...}`) e il risultato della
/// trascrizione (`{"type":"result",...}`).
///
/// Il canale e' cifrato quando il demone ha un certificato (self-signed,
/// generato da lui): l'app lo fissa al primo collegamento e da li' in poi
/// rifiuta un certificato diverso. Se il demone non ne ha (openssl mancante
/// sul PC) si ricade sul canale in chiaro delle versioni precedenti.
class StenoClient extends ChangeNotifier {
  Socket? _socket;
  StreamSubscription<String>? _sub;
  Timer? _reconnectTimer;
  ConnectionSettings? _settings;
  bool _disposed = false;
  bool _wantConnected = false;

  ConnectionStatus status = ConnectionStatus.disconnected;
  DaemonState daemonState = DaemonState.unknown;
  String? lastFailureReason;

  /// Se la connessione in corso e' cifrata, e con quale certificato.
  bool connectionSecure = false;
  String? peerFingerprint;

  /// Valorizzata quando il certificato presentato dal PC non corrisponde a
  /// quello fissato: finche' l'utente non decide (accetta il nuovo o
  /// corregge l'indirizzo) l'app non riprova da sola, per non insistere
  /// verso un possibile impostore.
  String? certificateMismatch;

  String? lastResultText;
  String? lastResultError;
  bool? lastPasted;
  /// "ai_command" (vedi [lastResultCombo]); `null` per il normale incolla
  /// di testo.
  String? lastResultKind;
  String? lastResultCombo;
  int resultVersion = 0;

  List<Dashboard> dashboards = const [];
  String? lastLayoutError;
  int layoutErrorVersion = 0;

  /// Id della dashboard suggerita in base all'app col focus sul PC (vedi
  /// "match" delle dashboard). `null` finche' il demone non ha ancora
  /// rilevato nulla di corrispondente.
  String? activeAppDashboardId;
  int activeAppVersion = 0;

  /// Scelta fra piu' scorciatoie in sospeso: il comando vocale IA e' stato
  /// interpretato come ambiguo dal demone, che non ha eseguito nulla e
  /// aspetta che l'utente scelga fra [pendingChoiceOptions]. Effimera: non
  /// viene salvata da nessuna parte e sparisce quando la scelta si chiude
  /// (scelta fatta, annullata, scaduta, o superata da una nuova dettatura).
  String? pendingChoiceRequestId;
  String? pendingChoiceText;
  List<ShortcutChoice> pendingChoiceOptions = const [];
  int pendingChoiceVersion = 0;

  /// Lingua di dettatura corrente del demone (codice ISO 639-1 o "auto").
  String dictationLanguage = 'it';
  bool restoreClipboard = false;
  /// Traduzione automatica del testo dettato (solo pulsanti "record"):
  /// [translateTarget] e' un codice ISO 639-1 (mai "auto"), [translateEngine]
  /// e' "whisper" (solo verso inglese) o "llm" (qualsiasi lingua, via LM
  /// Studio).
  bool translateEnabled = false;
  String translateTarget = 'en';
  String translateEngine = 'whisper';

  /// Termini che Whisper deve trascrivere correttamente in ogni contesto
  /// (vedi set_vocabulary in daemon.py); quello per dashboard sta invece in
  /// [Dashboard.vocabulary].
  String vocabulary = '';

  /// Se il testo dettato va approvato sul telefono prima di essere
  /// incollato (vedi [pendingPasteText]).
  bool confirmBeforePaste = false;

  /// Se il demone rifiuta le connessioni in chiaro, e se ha un certificato
  /// con cui cifrarle. [daemonFingerprint] e' l'impronta che dichiara di
  /// avere: serve a mostrarla nelle impostazioni accanto a quella davvero
  /// presentata durante la connessione.
  bool requireTls = false;
  bool tlsAvailable = false;
  String? daemonFingerprint;
  int configVersion = 0;

  /// Ultime dettature (dalla piu' recente), come le tiene il demone in
  /// memoria: l'app ne mostra l'anteprima e ne puo' chiedere il re-incolla.
  List<HistoryEntry> history = const [];
  int historyVersion = 0;

  /// Applicazioni installate sul PC, richieste su domanda (vedi
  /// [requestApps]) per creare un pulsante di avvio.
  List<LaunchableApp> apps = const [];
  int appsVersion = 0;

  /// Video/audio che il PC sta esponendo, in riproduzione o in pausa:
  /// l'app ne mostra un pulsante play/pausa per ciascuno. Vuota se il demone
  /// non rileva nulla o gira su una piattaforma senza supporto.
  List<MediaPlayerInfo> players = const [];

  /// Se il demone mette in pausa da solo i video mentre si detta.
  bool pauseMediaWhileRecording = false;

  /// Icone delle applicazioni del PC, richieste su domanda e tenute da
  /// parte: si disegnano in filigrana dietro i pulsanti della dashboard
  /// dedicata a quell'app. Il valore e' `null` per le applicazioni di cui il
  /// PC non ha trovato un'icona — la voce resta comunque, per non
  /// richiederla di nuovo ad ogni ricostruzione della schermata.
  final Map<String, Uint8List?> appIcons = {};
  int appIconsVersion = 0;

  /// Chiede l'icona di [appId] se non e' gia' stata chiesta. Torna subito:
  /// la risposta arriva come messaggio "app_icon" e fa ridisegnare la
  /// schermata.
  void requestAppIcon(String appId) {
    if (appIcons.containsKey(appId)) return;
    // segnaposto: evita di richiederla ad ogni frame mentre la risposta e'
    // ancora in viaggio
    appIcons[appId] = null;
    _sendCmd({'cmd': 'get_app_icon', 'app_id': appId});
  }

  /// Testo dettato in attesa di approvazione (solo con
  /// [confirmBeforePaste]): finche' e' valorizzato il demone non ha
  /// incollato nulla e sta aspettando. Effimero come la scelta fra
  /// scorciatoie ambigue.
  String? pendingPasteRequestId;
  String? pendingPasteText;
  int pendingPasteVersion = 0;

  void connect(ConnectionSettings settings) {
    _settings = settings;
    _wantConnected = true;
    _reconnectTimer?.cancel();
    _openSocket();
  }

  void disconnect() {
    _wantConnected = false;
    _reconnectTimer?.cancel();
    _closeSocket();
    status = ConnectionStatus.disconnected;
    daemonState = DaemonState.unknown;
    _notify();
  }

  /// Preme il pulsante [id]: se e' il pulsante "record" avvia/ferma la
  /// registrazione, altrimenti simula sul PC la combinazione di tasti
  /// associata.
  void pressButton(String id) {
    if (id == 'record' &&
        (daemonState == DaemonState.transcribing ||
            daemonState == DaemonState.loading)) {
      // Il demone ignora comunque il toggle in questi stati.
      return;
    }
    _sendCmd({'cmd': 'button', 'id': id});
  }

  /// Push-to-talk: pressione e rilascio del pulsante arrivano separati
  /// invece del singolo tocco che fa da interruttore. Sui pulsanti che non
  /// sono microfoni l'azione parte al [pressButtonDown] e il rilascio non
  /// fa nulla.
  void pressButtonDown(String id) {
    _sendCmd({'cmd': 'button_down', 'id': id});
  }

  void pressButtonUp(String id) {
    _sendCmd({'cmd': 'button_up', 'id': id});
  }

  /// Chiede l'elenco aggiornato delle applicazioni installate sul PC (la
  /// risposta arriva in [apps]): serve a creare un pulsante di avvio senza
  /// dover digitare a mano un id opaco.
  void requestApps() {
    _sendCmd({'cmd': 'list_apps'});
  }

  /// Re-incolla una dettatura passata. Il testo non viaggia da qui: il
  /// demone accetta solo l'id di una voce che ha gia' in memoria.
  void pasteHistoryEntry(String id) {
    _sendCmd({'cmd': 'paste_history', 'id': id});
  }

  /// Approva l'incolla in attesa, eventualmente con il testo corretto
  /// dall'utente ([text] nullo = si incolla quello proposto).
  void confirmPaste({String? text}) {
    final requestId = pendingPasteRequestId;
    if (requestId == null) return;
    final cmd = <String, dynamic>{
      'cmd': 'confirm_paste',
      'request_id': requestId,
    };
    if (text != null) cmd['text'] = text;
    _sendCmd(cmd);
  }

  void cancelPaste() {
    final requestId = pendingPasteRequestId;
    if (requestId == null) return;
    _sendCmd({'cmd': 'cancel_paste', 'request_id': requestId});
  }

  /// Mette in pausa (o fa riprendere) un video in riproduzione sul PC. Si
  /// manda l'azione voluta, non un interruttore: cosi' un elenco arrivato
  /// un istante prima non fa fare l'opposto di quello che si vede.
  void setMediaPlayerPlaying(String playerId, bool playing) {
    _sendCmd({
      'cmd': playing ? 'player_play' : 'player_pause',
      'id': playerId,
    });
  }

  void setPauseMediaWhileRecording(bool enabled) {
    _sendCmd({'cmd': 'set_pause_media_while_recording', 'enabled': enabled});
  }

  /// [kind] e' 'keys' (default, richiede [combo]), 'macro' (richiede
  /// [combos]), 'text' (richiede [text]), 'launch' (richiede [appId]),
  /// oppure uno dei tipi microfono ('record', 'ai_command'), che non
  /// richiedono altro.
  void addButton({
    required String dashboardId,
    required String label,
    required int row,
    required int col,
    String? combo,
    String kind = 'keys',
    List<String>? combos,
    int? delayMs,
    String? text,
    String? appId,
  }) {
    final cmd = <String, dynamic>{
      'cmd': 'add_button',
      'dashboard_id': dashboardId,
      'label': label,
      'kind': kind,
      'row': row,
      'col': col,
    };
    if (combo != null) cmd['combo'] = combo;
    if (combos != null) cmd['combos'] = combos;
    if (delayMs != null) cmd['delay_ms'] = delayMs;
    if (text != null) cmd['text'] = text;
    if (appId != null) cmd['app_id'] = appId;
    _sendCmd(cmd);
  }

  void removeButton(String id) {
    _sendCmd({'cmd': 'remove_button', 'id': id});
  }

  void moveButton(String id, int row, int col) {
    _sendCmd({'cmd': 'move_button', 'id': id, 'row': row, 'col': col});
  }

  /// Modifica un pulsante esistente senza ricrearlo: etichetta e azione
  /// (combinazione di tasti, sequenza della macro, snippet di testo). I
  /// campi omessi restano com'erano; il demone rifiuta un campo che non
  /// appartiene al tipo del pulsante.
  void editButton(
    String id, {
    String? label,
    String? combo,
    List<String>? combos,
    int? delayMs,
    String? text,
  }) {
    final cmd = <String, dynamic>{'cmd': 'edit_button', 'id': id};
    if (label != null) cmd['label'] = label;
    if (combo != null) cmd['combo'] = combo;
    if (combos != null) cmd['combos'] = combos;
    if (delayMs != null) cmd['delay_ms'] = delayMs;
    if (text != null) cmd['text'] = text;
    _sendCmd(cmd);
  }

  void setButtonStyle(String id, {String? color, String? icon}) {
    final cmd = <String, dynamic>{'cmd': 'set_button_style', 'id': id};
    if (color != null) cmd['color'] = color;
    if (icon != null) cmd['icon'] = icon;
    _sendCmd(cmd);
  }

  void setGridSize(String dashboardId, int rows, int cols) {
    _sendCmd({
      'cmd': 'set_grid_size',
      'dashboard_id': dashboardId,
      'rows': rows,
      'cols': cols,
    });
  }

  void createDashboard(String name) {
    _sendCmd({'cmd': 'create_dashboard', 'name': name});
  }

  void removeDashboard(String id) {
    _sendCmd({'cmd': 'remove_dashboard', 'id': id});
  }

  void renameDashboard(String id, String name) {
    _sendCmd({'cmd': 'rename_dashboard', 'id': id, 'name': name});
  }

  void setDashboardMatch(String id, String match) {
    _sendCmd({'cmd': 'set_dashboard_match', 'id': id, 'match': match});
  }

  void setDashboardVocabulary(String id, String vocabulary) {
    _sendCmd({
      'cmd': 'set_dashboard_vocabulary',
      'dashboard_id': id,
      'vocabulary': vocabulary,
    });
  }

  void setVocabulary(String value) {
    _sendCmd({'cmd': 'set_vocabulary', 'vocabulary': value});
  }

  void setConfirmBeforePaste(bool enabled) {
    _sendCmd({'cmd': 'set_confirm_before_paste', 'enabled': enabled});
  }

  void setRequireTls(bool enabled) {
    _sendCmd({'cmd': 'set_require_tls', 'enabled': enabled});
  }

  void resetLayout() {
    _sendCmd({'cmd': 'reset_layout'});
  }

  void reorderDashboard(String id, int position) {
    _sendCmd({'cmd': 'reorder_dashboard', 'id': id, 'position': position});
  }

  void duplicateDashboard(String id, {String? name}) {
    final cmd = <String, dynamic>{'cmd': 'duplicate_dashboard', 'id': id};
    if (name != null) cmd['name'] = name;
    _sendCmd(cmd);
  }

  void setDictationLanguage(String language) {
    _sendCmd({'cmd': 'set_language', 'language': language});
  }

  void setRestoreClipboard(bool enabled) {
    _sendCmd({'cmd': 'set_restore_clipboard', 'enabled': enabled});
  }

  void setTranslateEnabled(bool enabled) {
    _sendCmd({'cmd': 'set_translate_enabled', 'enabled': enabled});
  }

  void setTranslateTarget(String target) {
    _sendCmd({'cmd': 'set_translate_target', 'target': target});
  }

  void setTranslateEngine(String engine) {
    _sendCmd({'cmd': 'set_translate_engine', 'engine': engine});
  }

  /// Riavvia il demone sul PC (stesso processo, si ripresenta con lo
  /// stesso token/porta): la connessione si interrompe per qualche
  /// secondo, poi il client si riconnette da solo (vedi _scheduleReconnect).
  void restartDaemon() {
    _sendCmd({'cmd': 'restart_daemon'});
  }

  /// Esegue una delle opzioni proposte per un comando vocale ambiguo (una
  /// combinazione di tasti, una macro multi-passo o l'avvio di
  /// un'applicazione). Il demone accetta solo opzioni presenti fra quelle
  /// che ha inviato.
  void chooseShortcut(ShortcutChoice choice) {
    final requestId = pendingChoiceRequestId;
    if (requestId == null) return;
    final cmd = <String, dynamic>{
      'cmd': 'choose_shortcut',
      'request_id': requestId,
    };
    if (choice.isApp) {
      cmd['app_id'] = choice.appId;
    } else if (choice.isMacro) {
      cmd['combos'] = choice.combos;
    } else {
      cmd['combo'] = choice.combo;
    }
    _sendCmd(cmd);
  }

  /// Chiude la scelta senza eseguire nulla.
  void cancelShortcutChoice() {
    final requestId = pendingChoiceRequestId;
    if (requestId == null) return;
    _sendCmd({'cmd': 'cancel_shortcut_choice', 'request_id': requestId});
  }

  void _sendCmd(Map<String, dynamic> obj) {
    final socket = _socket;
    if (status != ConnectionStatus.connected || socket == null) return;
    _send(socket, obj);
  }

  Future<void> _openSocket() async {
    final settings = _settings;
    if (settings == null) return;

    status = ConnectionStatus.connecting;
    lastFailureReason = null;
    _notify();

    try {
      final connection = await openDaemonConnection(settings);
      final socket = connection.socket;
      _socket = socket;
      connectionSecure = connection.secure;
      peerFingerprint = connection.fingerprint;
      certificateMismatch = null;
      _send(socket, {'cmd': 'auth', 'token': settings.token});

      _sub = utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .listen(
            _onLine,
            onError: (_) => _handleDisconnect(),
            onDone: _handleDisconnect,
            cancelOnError: true,
          );
    } on CertificateMismatch catch (e) {
      // niente riconnessione automatica: si insisterebbe a bussare a un PC
      // che potrebbe non essere il proprio
      _wantConnected = false;
      certificateMismatch = e.presented;
      lastFailureReason =
          'Il certificato del PC e\' cambiato. Verificalo nelle impostazioni '
          'prima di riconnetterti.';
      status = ConnectionStatus.error;
      _notify();
    } catch (e) {
      lastFailureReason = 'Connessione fallita: $e';
      status = ConnectionStatus.error;
      _notify();
      _scheduleReconnect();
    }
  }

  /// Dimentica il certificato fissato e riprova a collegarsi: usato quando
  /// l'utente conferma che il cambio di certificato e' legittimo (demone
  /// reinstallato).
  Future<void> trustNewCertificate() async {
    await SettingsService().savePinnedCertificate(null);
    certificateMismatch = null;
    final settings = _settings;
    if (settings != null) connect(settings);
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    switch (msg['type']) {
      case 'auth':
        if (msg['ok'] == true) {
          status = ConnectionStatus.connected;
          lastFailureReason = null;
        } else {
          final reason = msg['reason'] as String?;
          final error = msg['error'] as String?;
          // Solo un token sbagliato va corretto a mano: gli altri rifiuti
          // (connessione non cifrata verso un demone che pretende TLS,
          // troppi tentativi ravvicinati) passano da soli, quindi la
          // riconnessione automatica deve continuare invece di fermarsi
          // fino alla riapertura dell'app.
          // Un demone precedente non manda "reason": mandava un "error"
          // solo per i rifiuti temporanei e nulla per il token sbagliato.
          final badToken = reason == null ? error == null : reason == 'bad_token';
          // per il token sbagliato il messaggio lo mette l'app (tradotto),
          // per gli altri rifiuti serve la spiegazione del demone
          lastFailureReason = badToken ? null : error;
          if (badToken) {
            status = ConnectionStatus.authFailed;
            _wantConnected = false;
            _closeSocket();
          } else {
            status = ConnectionStatus.error;
            _closeSocket();
            // il rate limit dura una finestra intera lato demone: inutile
            // ribussare subito
            _scheduleReconnect(
              delay: reason == 'rate_limited'
                  ? const Duration(seconds: 20)
                  : null,
            );
          }
        }
        break;
      case 'state':
        daemonState = daemonStateFromString(msg['state'] as String?);
        break;
      case 'result':
        lastResultText = msg['text'] as String?;
        lastResultError = msg['error'] as String?;
        lastPasted = msg['pasted'] as bool?;
        lastResultKind = msg['kind'] as String?;
        lastResultCombo = msg['combo'] as String?;
        resultVersion++;
        break;
      case 'layout':
        final rawDashboards = msg['dashboards'] as List<dynamic>? ?? const [];
        dashboards = rawDashboards
            .map((d) => Dashboard.fromJson(d as Map<String, dynamic>))
            .toList();
        break;
      case 'layout_result':
        if (msg['ok'] != true) {
          lastLayoutError = msg['error'] as String?;
          layoutErrorVersion++;
        }
        break;
      case 'active_app':
        activeAppDashboardId = msg['dashboard_id'] as String?;
        activeAppVersion++;
        break;
      case 'choose_shortcut':
        pendingChoiceRequestId = msg['request_id'] as String?;
        pendingChoiceText = msg['text'] as String?;
        pendingChoiceOptions = (msg['options'] as List<dynamic>? ?? const [])
            .map((o) => ShortcutChoice.fromJson(o as Map<String, dynamic>))
            .toList();
        pendingChoiceVersion++;
        break;
      case 'choose_shortcut_closed':
        // il demone ha chiuso la richiesta (scelta eseguita, scaduta,
        // annullata o superata): il pannello va chiuso anche se la scelta
        // e' avvenuta da un altro telefono collegato
        if (pendingChoiceRequestId == msg['request_id']) {
          pendingChoiceRequestId = null;
          pendingChoiceText = null;
          pendingChoiceOptions = const [];
          pendingChoiceVersion++;
        }
        break;
      case 'config':
        dictationLanguage = msg['language'] as String? ?? dictationLanguage;
        restoreClipboard = msg['restore_clipboard'] as bool? ?? restoreClipboard;
        translateEnabled = msg['translate_enabled'] as bool? ?? translateEnabled;
        translateTarget = msg['translate_target'] as String? ?? translateTarget;
        translateEngine = msg['translate_engine'] as String? ?? translateEngine;
        vocabulary = msg['vocabulary'] as String? ?? vocabulary;
        confirmBeforePaste =
            msg['confirm_before_paste'] as bool? ?? confirmBeforePaste;
        requireTls = msg['require_tls'] as bool? ?? requireTls;
        pauseMediaWhileRecording =
            msg['pause_media_while_recording'] as bool? ??
            pauseMediaWhileRecording;
        tlsAvailable = msg['tls_available'] as bool? ?? tlsAvailable;
        daemonFingerprint = msg['tls_fingerprint'] as String?;
        configVersion++;
        break;
      case 'history':
        history = (msg['items'] as List<dynamic>? ?? const [])
            .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
            .toList();
        historyVersion++;
        break;
      case 'apps':
        apps = (msg['apps'] as List<dynamic>? ?? const [])
            .map((a) => LaunchableApp.fromJson(a as Map<String, dynamic>))
            .toList();
        appsVersion++;
        break;
      case 'app_icon':
        final appId = msg['app_id'] as String?;
        final encoded = msg['png'] as String?;
        if (appId != null) {
          appIcons[appId] = encoded == null
              ? null
              : Uint8List.fromList(base64Decode(encoded));
          appIconsVersion++;
        }
        break;
      case 'players':
        players = (msg['players'] as List<dynamic>? ?? const [])
            .map((p) => MediaPlayerInfo.fromJson(p as Map<String, dynamic>))
            .toList();
        break;
      case 'confirm_paste':
        pendingPasteRequestId = msg['request_id'] as String?;
        pendingPasteText = msg['text'] as String?;
        pendingPasteVersion++;
        break;
      case 'confirm_paste_closed':
        // il demone ha ritirato la richiesta (confermata, annullata,
        // scaduta o superata da una nuova dettatura): vale anche quando la
        // conferma e' arrivata da un altro telefono collegato
        if (pendingPasteRequestId == msg['request_id']) {
          pendingPasteRequestId = null;
          pendingPasteText = null;
          pendingPasteVersion++;
        }
        break;
      case 'config_result':
        if (msg['ok'] != true) {
          // riusa lo stesso canale di visualizzazione errori del layout:
          // e' comunque un errore di validazione di un comando dell'utente
          lastLayoutError = msg['error'] as String?;
          layoutErrorVersion++;
        }
        break;
    }
    _notify();
  }

  void _handleDisconnect() {
    _sub?.cancel();
    _sub = null;
    _socket?.destroy();
    _socket = null;
    if (status != ConnectionStatus.authFailed) {
      status = ConnectionStatus.disconnected;
    }
    daemonState = DaemonState.unknown;
    connectionSecure = false;
    _notify();
    if (_wantConnected) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect({Duration? delay}) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay ?? const Duration(seconds: 3), () {
      if (_wantConnected) _openSocket();
    });
  }

  void _closeSocket() {
    _sub?.cancel();
    _sub = null;
    _socket?.destroy();
    _socket = null;
  }

  void _send(Socket socket, Map<String, dynamic> obj) {
    socket.add(utf8.encode('${jsonEncode(obj)}\n'));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _closeSocket();
    super.dispose();
  }
}

/// Apre una connessione verso il demone, cifrata se il PC ha un certificato.
///
/// Il certificato e' self-signed, quindi nessuna autorita' lo garantisce: al
/// posto della verifica standard si usa il "trust on first use", cioe' si
/// accetta quello visto al primo collegamento e lo si pretende identico da
/// li' in avanti (vedi [SettingsService.loadPinnedCertificate]). Se il PC
/// non risponde in TLS — demone vecchio, o senza openssl per generare il
/// certificato — si ricade sulla connessione in chiaro, che il demone
/// riconosce sulla stessa porta.
Future<DaemonConnection> openDaemonConnection(ConnectionSettings settings) async {
  const timeout = Duration(seconds: 5);
  final service = SettingsService();
  final pinned = await service.loadPinnedCertificate();

  String? presented;
  bool rejectedByPinning = false;
  try {
    final socket = await SecureSocket.connect(
      settings.host,
      settings.port,
      timeout: timeout,
      onBadCertificate: (certificate) {
        presented = formatFingerprint(certificate.sha1);
        if (pinned == null) return true; // primo collegamento: si fissa dopo
        if (pinned == presented) return true;
        rejectedByPinning = true;
        return false;
      },
    );
    if (pinned == null && presented != null) {
      await service.savePinnedCertificate(presented);
    }
    return DaemonConnection(socket, secure: true, fingerprint: presented);
  } catch (e) {
    if (rejectedByPinning) {
      throw CertificateMismatch(presented ?? '');
    }
    if (pinned != null) {
      // questo PC ha gia' parlato TLS (il suo certificato e' fissato):
      // l'handshake fallito e' un problema momentaneo di rete, non un
      // demone senza TLS. Ricadere in chiaro qui e' quello che faceva
      // rifiutare la connessione da un demone con require_tls attivo,
      // lasciando l'app "non connessa" fino alla riapertura: meglio
      // propagare l'errore e lasciare che il ciclo di riconnessione
      // ritenti in TLS.
      rethrow;
    }
    // il PC non parla TLS: si prosegue in chiaro (a meno che non lo
    // rifiuti, nel qual caso il demone risponde con un errore esplicito)
    final socket = await Socket.connect(
      settings.host,
      settings.port,
      timeout: timeout,
    );
    return DaemonConnection(socket, secure: false);
  }
}

/// Connessione una tantum usata dalla schermata impostazioni per verificare
/// indirizzo, porta e token prima di salvarli.
Future<String> testConnection(ConnectionSettings settings) async {
  Socket? socket;
  StreamSubscription<String>? sub;
  try {
    socket = (await openDaemonConnection(settings)).socket;
    final completer = Completer<String>();
    sub = utf8.decoder.bind(socket).transform(const LineSplitter()).listen(
      (line) {
        try {
          final msg = jsonDecode(line) as Map<String, dynamic>;
          if (msg['type'] == 'auth' && !completer.isCompleted) {
            final error = msg['error'] as String?;
            completer.complete(
              msg['ok'] == true
                  ? 'Connessione riuscita'
                  : (error ?? 'Token non valido'),
            );
          }
        } catch (_) {
          // riga non valida, ignorata
        }
      },
      onError: (_) {
        if (!completer.isCompleted) {
          completer.complete('Errore di connessione');
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete('Connessione chiusa senza risposta');
        }
      },
    );
    socket.add(
      utf8.encode('${jsonEncode({
        'cmd': 'auth',
        'token': settings.token,
      })}\n'),
    );
    return await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 'Timeout: PC non raggiungibile',
    );
  } catch (e) {
    return 'Impossibile connettersi: $e';
  } finally {
    await sub?.cancel();
    socket?.destroy();
  }
}
