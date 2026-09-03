import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../l10n/strings.dart';
import '../models/button_spec.dart';
import '../models/daemon_state.dart';
import '../services/locale_service.dart';
import '../services/settings_service.dart';
import '../services/steno_client.dart';
import '../services/wake_word_service.dart';
import 'history_screen.dart';
import 'settings_screen.dart';

/// Quanti pulsanti play/pausa mostrare al massimo nella colonna a destra
/// (vedi _buildMediaPlayerButtons): oltre, la colonna arriverebbe a coprire
/// la griglia.
const _maxMediaPlayerButtons = 5;

/// Quanto sono coprenti i pulsanti: sotto la griglia c'e' l'icona
/// dell'applicazione della dashboard (vedi _buildDashboardBackdrop), che
/// deve restare intuibile senza che le etichette perdano leggibilita'.
const _cellOpacity = 0.82;

/// Massima estensione di un pulsante in celle: stesso limite di
/// BUTTON_MAX_SPAN in daemon.py, che e' comunque l'ultima parola.
const _maxButtonSpan = 8;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.client, required this.locale});

  final StenoClient client;
  final LocaleService locale;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Strings get _s => Strings(widget.locale.language);

  final _pageController = PageController();
  int _currentPage = 0;

  int _lastShownResultVersion = 0;
  int _lastShownLayoutErrorVersion = 0;
  int _lastShownActiveAppVersion = 0;
  int _lastShownChoiceVersion = 0;
  int _lastShownPasteVersion = 0;
  /// true mentre il pannello di scelta fra scorciatoie ambigue e' aperto:
  /// serve a chiuderlo da codice se e' il demone a ritirare la richiesta
  /// (timeout, oppure scelta gia' fatta da un altro telefono collegato).
  bool _choiceSheetOpen = false;
  /// stessa cosa per il pannello di conferma dell'incolla
  bool _pasteSheetOpen = false;
  bool _editMode = false;
  bool _followActiveApp = false;
  bool _pushToTalk = false;
  bool _haptics = true;
  bool _phoneWakeWord = false;
  /// true mentre la dettatura in corso viene trascritta dal telefono invece
  /// che dal PC (vedi _phoneShouldTranscribe)
  bool _dictatingOnPhone = false;
  /// Ascolto della frase di attivazione col microfono del telefono. E'
  /// indipendente da quello del PC (config `wake_word_enabled` del demone):
  /// l'utente puo' tenerne acceso uno, l'altro o entrambi.
  late final WakeWordService _wakeWord;
  /// ultimo stato del demone gia' "vibrato": serve a far vibrare solo alle
  /// transizioni (inizio/fine registrazione) e non ad ogni notifica
  DaemonState _lastHapticState = DaemonState.unknown;
  String? _flashingButtonId;
  /// Pulsante microfono (record/ai_command) che ha avviato la
  /// sessione in corso: finche' il demone e' occupato gli altri microfoni
  /// restano disabilitati, cosi' non si puo' fermare una dettatura normale
  /// con il pulsante IA (o viceversa) prendendosi il risultato sbagliato.
  String? _micOwnerButtonId;
  /// true quando il demone e' effettivamente uscito da "idle" dopo la
  /// pressione: distingue la sessione avviata da un tocco andato a buon
  /// fine da un tocco a vuoto (vedi [_trackMicSession])
  bool _micSessionStarted = false;
  DateTime? _micOwnerSince;

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onClientChanged);
    widget.locale.addListener(_onLocaleChanged);
    widget.locale.load();
    WakelockPlus.enable();
    _wakeWord = WakeWordService()
      // le frasi e la lingua sono quelle del demone, lette al momento
      // dell'uso: cambiarle dalle impostazioni ha effetto subito
      ..startPhrase = (() => widget.client.wakePhraseStart)
      ..stopPhrase = (() => widget.client.wakePhraseStop)
      ..localeId = _recognizerLocale
      ..dictationInProgress = (() =>
          widget.client.daemonState == DaemonState.recording)
      ..onStart = _onWakePhraseStart
      ..onStop = _onWakePhraseStop;
    _wakeWord.addListener(_onLocaleChanged);
    _loadAndConnect();
    _loadLocalPreferences();
  }

  Future<void> _loadLocalPreferences() async {
    final service = SettingsService();
    final follow = await service.loadFollowActiveApp();
    final pushToTalk = await service.loadPushToTalk();
    final haptics = await service.loadHapticFeedback();
    final phoneWakeWord = await service.loadPhoneWakeWord();
    final silenceBeeps = await service.loadSilenceBeeps();
    if (!mounted) return;
    setState(() {
      _followActiveApp = follow;
      _pushToTalk = pushToTalk;
      _haptics = haptics;
      _phoneWakeWord = phoneWakeWord;
    });
    _wakeWord.silenceBeeps = silenceBeeps;
    _syncWakeWordListening();
  }

  /// Lingua da passare al riconoscitore del telefono: quella della dettatura
  /// scelta sul demone, cosi' la frase viene interpretata come la pronuncia
  /// l'utente. Con "auto" il telefono non ha una lingua da indovinare, si usa
  /// quella dell'interfaccia.
  String _recognizerLocale() {
    final language = widget.client.dictationLanguage;
    if (language == 'auto' || language.length != 2) {
      return widget.locale.language == AppLanguage.it ? 'it_IT' : 'en_US';
    }
    return '${language}_${language.toUpperCase()}';
  }

  /// Accende l'ascolto sul telefono solo se serve davvero: senza connessione
  /// il comando non arriverebbe da nessuna parte, e tenere aperto il
  /// microfono a vuoto consumerebbe batteria.
  void _syncWakeWordListening() {
    final wanted =
        _phoneWakeWord &&
        widget.client.status == ConnectionStatus.connected;
    if (wanted == _wakeWord.enabled) return;
    _wakeWord.setEnabled(wanted).then((_) {
      if (!mounted || !wanted || !_wakeWord.unavailable) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_s.wakeWordPhoneUnavailable),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 4),
        ),
      );
    });
  }

  /// Frase di avvio sentita dal telefono: si comporta come un tocco sul
  /// pulsante microfono della dashboard aperta, cosi' la dettatura eredita il
  /// vocabolario della dashboard e l'invio automatico del pulsante. Se il
  /// demone e' gia' occupato non c'e' niente da avviare.
  void _onWakePhraseStart() {
    if (!mounted || _daemonBusy) return;
    final button = _recordButtonForWakeWord();
    if (button == null) {
      widget.client.toggleRecordingByVoice();
      return;
    }
    _claimMicSession(button);
    _pressRecordButton(button, byVoice: true);
  }

  /// Frase di stop: ferma la dettatura in corso, e solo quella. Preme il
  /// pulsante che l'ha avviata, perche' e' l'unico che il demone accetta per
  /// fermarla (vedi [_isMicLocked]).
  void _onWakePhraseStop() {
    if (!mounted) return;
    if (widget.client.daemonState != DaemonState.recording) return;
    if (_dictatingOnPhone) {
      // a trascrivere e' il telefono: fermare vuol dire consegnare il testo
      _finishPhoneDictation();
      return;
    }
    final owner = _micOwnerButtonId;
    if (owner != null) {
      widget.client.pressButtonByVoice(owner);
      return;
    }
    final button = _recordButtonForWakeWord();
    if (button == null) {
      widget.client.toggleRecordingByVoice();
    } else {
      widget.client.pressButtonByVoice(button.id);
    }
  }

  /// Il pulsante di dettatura da usare per l'attivazione vocale: quello della
  /// dashboard aperta se c'e', altrimenti il primo che si trova nelle altre.
  ButtonSpec? _recordButtonForWakeWord() {
    final dashboards = _pageDashboards;
    if (dashboards.isEmpty) return null;
    final ordered = [
      if (_currentPage < dashboards.length) dashboards[_currentPage],
      ...dashboards,
    ];
    for (final dashboard in ordered) {
      for (final button in dashboard.buttons) {
        if (button.isRecord) return button;
      }
    }
    return null;
  }

  void _onLocaleChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClientChanged);
    widget.locale.removeListener(_onLocaleChanged);
    _wakeWord.removeListener(_onLocaleChanged);
    _wakeWord.dispose();
    _pageController.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _loadAndConnect() async {
    final settings = await SettingsService().load();
    if (!mounted) return;
    if (settings.isComplete) {
      widget.client.connect(settings);
    } else {
      _openSettings();
    }
  }

  /// Dashboard raggiungibili con lo swipe.
  List<Dashboard> get _pageDashboards => widget.client.dashboards;

  void _onClientChanged() {
    if (!mounted) return;
    final dashboardCount = _pageDashboards.length;
    if (dashboardCount > 0 && _currentPage >= dashboardCount) {
      _currentPage = dashboardCount - 1;
    }
    setState(() {});
    if (widget.client.resultVersion != _lastShownResultVersion) {
      _lastShownResultVersion = widget.client.resultVersion;
      _showResultFeedback();
    }
    if (widget.client.layoutErrorVersion != _lastShownLayoutErrorVersion) {
      _lastShownLayoutErrorVersion = widget.client.layoutErrorVersion;
      final error = widget.client.lastLayoutError;
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
    if (widget.client.activeAppVersion != _lastShownActiveAppVersion) {
      _lastShownActiveAppVersion = widget.client.activeAppVersion;
      _maybeFollowActiveApp();
    }
    if (widget.client.pendingChoiceVersion != _lastShownChoiceVersion) {
      _lastShownChoiceVersion = widget.client.pendingChoiceVersion;
      _syncShortcutChoiceSheet();
    }
    if (widget.client.pendingPasteVersion != _lastShownPasteVersion) {
      _lastShownPasteVersion = widget.client.pendingPasteVersion;
      _syncConfirmPasteSheet();
    }
    _maybeVibrateForState();
    _trackMicSession();
    // i segnali acustici del riconoscimento restano muti mentre si aspetta la
    // frase e tornano udibili durante la dettatura (vedi SystemSounds)
    _wakeWord.setDictating(
      widget.client.daemonState == DaemonState.recording,
    );
    if (_dictatingOnPhone &&
        widget.client.daemonState != DaemonState.recording) {
      // il PC ha chiuso la dettatura per conto suo (rete di sicurezza sulla
      // durata, o un altro telefono): la raccolta va chiusa comunque, senza
      // consegnare un testo che nessuno aspetta piu'
      setState(() => _dictatingOnPhone = false);
      _wakeWord.stopCollecting();
    }
    // la connessione puo' essere appena caduta o tornata: l'ascolto sul
    // telefono va spento e riacceso di conseguenza
    _syncWakeWordListening();
  }

  /// true quando il demone sta gia' facendo qualcosa (registrazione,
  /// trascrizione, elaborazione IA, caricamento modello): in questi stati
  /// non puo' accettare una seconda dettatura.
  bool get _daemonBusy {
    switch (widget.client.daemonState) {
      case DaemonState.recording:
      case DaemonState.transcribing:
      case DaemonState.thinking:
      case DaemonState.loading:
        return true;
      case DaemonState.idle:
      case DaemonState.unknown:
        return false;
    }
  }

  /// Tiene aggiornato il "proprietario" della sessione microfono: la
  /// prenotazione fatta al tocco vale finche' il demone e' occupato, e
  /// decade da sola sia a fine sessione sia se il demone non e' mai partito
  /// (comando perso, demone che ha ignorato il pulsante).
  void _trackMicSession() {
    if (_micOwnerButtonId == null) return;
    if (_daemonBusy) {
      _micSessionStarted = true;
      return;
    }
    final since = _micOwnerSince;
    final expired =
        since != null && DateTime.now().difference(since).inSeconds >= 5;
    if (_micSessionStarted || expired) {
      _micOwnerButtonId = null;
      _micOwnerSince = null;
      _micSessionStarted = false;
    }
  }

  /// Un microfono e' bloccato quando la sessione in corso e' stata avviata
  /// da un altro microfono: solo quello che l'ha avviata puo' fermarla.
  bool _isMicLocked(ButtonSpec button) =>
      _micOwnerButtonId != null &&
      _micOwnerButtonId != button.id &&
      _daemonBusy;

  /// Prenota la sessione per il microfono toccato (vedi [_isMicLocked]).
  void _claimMicSession(ButtonSpec button) {
    _micOwnerButtonId = button.id;
    _micOwnerSince = DateTime.now();
    _micSessionStarted = false;
  }

  /// Vibra alle transizioni di stato che l'utente non puo' vedere altrove:
  /// il riscontro scritto del demone e' una notifica sul PC, cioe' proprio
  /// dove non sta guardando mentre tiene il telefono in mano.
  void _maybeVibrateForState() {
    final state = widget.client.daemonState;
    if (state == _lastHapticState) return;
    final previous = _lastHapticState;
    _lastHapticState = state;
    if (!_haptics) return;
    if (state == DaemonState.recording) {
      HapticFeedback.mediumImpact();
    } else if (previous == DaemonState.recording) {
      // fine registrazione: parte la trascrizione (o l'elaborazione IA)
      HapticFeedback.lightImpact();
    }
  }

  /// Apre il pannello di scelta quando il demone segnala un comando vocale
  /// ambiguo, e lo chiude quando la richiesta viene ritirata.
  void _syncShortcutChoiceSheet() {
    final hasPending = widget.client.pendingChoiceRequestId != null &&
        widget.client.pendingChoiceOptions.isNotEmpty;
    if (hasPending && !_choiceSheetOpen) {
      _showShortcutChoiceSheet();
    } else if (!hasPending && _choiceSheetOpen) {
      // richiesta ritirata dal demone: si chiude senza rimandargli nulla
      _choiceSheetOpen = false;
      Navigator.of(context).pop();
    }
  }

  Future<void> _showShortcutChoiceSheet() async {
    final options = widget.client.pendingChoiceOptions;
    final text = widget.client.pendingChoiceText ?? '';
    _choiceSheetOpen = true;
    ShortcutChoice? chosen;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _s.ambiguousCommandTitle,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                _s.ambiguousCommandSubtitle(text),
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              // stessa griglia a 2 colonne dei pulsanti veri, cosi' il
              // pannello si tocca come il resto dell'app
              Flexible(
                child: GridView.count(
                  shrinkWrap: true,
                  crossAxisCount: 2,
                  childAspectRatio: 1.6,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  children: [
                    for (final option in options)
                      FilledButton.tonal(
                        onPressed: () {
                          chosen = option;
                          Navigator.of(context).pop();
                        },
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (option.isApp)
                              const Icon(Icons.rocket_launch, size: 18),
                            if (option.isMacro)
                              const Icon(Icons.playlist_play, size: 18),
                            Text(
                              option.label,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              option.detail,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(_s.cancel),
              ),
            ],
          ),
        ),
      ),
    );
    // il pannello puo' chiudersi anche con uno swipe verso il basso o col
    // tasto indietro: in tutti i casi in cui non e' stata scelta un'opzione
    // il demone va avvisato, altrimenti resterebbe in attesa fino al timeout
    if (!_choiceSheetOpen) return; // gia' ritirata dal demone
    _choiceSheetOpen = false;
    if (chosen != null) {
      widget.client.chooseShortcut(chosen!);
    } else {
      widget.client.cancelShortcutChoice();
    }
  }

  /// Apre il pannello di conferma quando il demone chiede l'approvazione
  /// prima di incollare, e lo chiude quando la richiesta viene ritirata.
  void _syncConfirmPasteSheet() {
    final hasPending = widget.client.pendingPasteRequestId != null;
    if (hasPending && !_pasteSheetOpen) {
      _showConfirmPasteSheet();
    } else if (!hasPending && _pasteSheetOpen) {
      _pasteSheetOpen = false;
      Navigator.of(context).pop();
    }
  }

  Future<void> _showConfirmPasteSheet() async {
    final controller = TextEditingController(
      text: widget.client.pendingPasteText ?? '',
    );
    _pasteSheetOpen = true;
    bool confirmed = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        // lascia spazio alla tastiera: il testo qui si corregge a mano
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _s.confirmPasteTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  _s.confirmPasteHelper,
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: false,
                  maxLines: 6,
                  minLines: 2,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(_s.cancel),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () {
                          confirmed = true;
                          Navigator.of(context).pop();
                        },
                        icon: const Icon(Icons.content_paste),
                        label: Text(_s.confirmPasteButton),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // come per la scelta fra scorciatoie: chiudendo con lo swipe o col tasto
    // indietro il demone va comunque avvisato, altrimenti resta in attesa
    if (!_pasteSheetOpen) return; // gia' ritirata dal demone
    _pasteSheetOpen = false;
    if (confirmed) {
      widget.client.confirmPaste(text: controller.text);
    } else {
      widget.client.cancelPaste();
    }
  }

  void _maybeFollowActiveApp() {
    if (!_followActiveApp || _editMode) return;
    final targetId = widget.client.activeAppDashboardId;
    if (targetId == null) return;
    final index = _pageDashboards.indexWhere((d) => d.id == targetId);
    if (index == -1 || index == _currentPage) return;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _openHistoryScreen() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            HistoryScreen(client: widget.client, locale: widget.locale),
      ),
    );
  }

  void _toggleFollowActiveApp() {
    setState(() => _followActiveApp = !_followActiveApp);
    SettingsService().saveFollowActiveApp(_followActiveApp);
  }

  void _showResultFeedback() {
    final client = widget.client;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();

    if (client.lastResultError != null) {
      if (_haptics) HapticFeedback.heavyImpact();
      messenger.showSnackBar(
        SnackBar(
          content: Text(client.lastResultError!),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }

    if (client.lastResultKind == 'launch') {
      final name = client.lastResultText;
      if (name != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(_s.appLaunched(name)),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    if (client.lastResultKind == 'ai_command') {
      final combo = client.lastResultCombo;
      if (combo != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(_s.commandExecuted(combo)),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    final text = client.lastResultText;
    if (text != null) {
      final pasted = client.lastPasted == true;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${pasted ? _s.pastedOnPc : _s.copiedManualPaste}: $text',
          ),
          backgroundColor: pasted
              ? Colors.green.shade700
              : Colors.orange.shade700,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          client: widget.client,
          locale: widget.locale,
          wakeWord: _wakeWord,
        ),
      ),
    );
    // ogni impostazione (connessione compresa) si salva e si applica da
    // sola in SettingsScreen non appena viene modificata, non solo alla
    // chiusura: le preferenze locali (push-to-talk, vibrazione, segui app
    // attiva) vanno pero' ricaricate qui, altrimenti restano quelle lette
    // all'avvio finche' l'app non viene riaperta da zero
    await _loadLocalPreferences();
  }

  void _handleCellTap(Dashboard dashboard, int row, int col, ButtonSpec? button) {
    final client = widget.client;
    if (client.status != ConnectionStatus.connected) {
      _openSettings();
      return;
    }
    if (_editMode) {
      if (button == null) {
        _showAddButtonDialog(dashboard, row, col);
      }
      // tocco su un pulsante esistente in modalita' modifica: nessuna
      // azione. La rimozione passa dall'icona X dedicata, lo spostamento
      // dal trascinamento della cella (vedi _buildKeysCell/_buildRecordCell).
      return;
    }
    if (button == null) return;
    final isMic = button.isRecord || button.isAiCommand;
    if (isMic) {
      // il tocco su un microfono bloccato non arriva qui (vedi
      // _buildMicCell): qui si registra solo chi apre la sessione
      if (!_daemonBusy) _claimMicSession(button);
    }
    setState(() => _flashingButtonId = button.id);
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _flashingButtonId = null);
    });
    if (button.isRecord) {
      _pressRecordButton(button);
      return;
    }
    client.pressButton(button.id);
  }

  /// Se sia il telefono a doversi occupare della trascrizione: succede quando
  /// il PC non puo' usare la GPU, dove Whisper impiega all'incirca il tempo
  /// reale. Il riconoscimento del telefono e' immediato, a costo di una
  /// trascrizione un po' piu' grezza.
  bool get _phoneShouldTranscribe =>
      widget.client.pcTranscriptionIsSlow && !_wakeWord.unavailable;

  /// Tocco su un pulsante di dettatura: avvia, oppure ferma consegnando il
  /// testo se a trascrivere e' stato il telefono.
  Future<void> _pressRecordButton(ButtonSpec button, {bool byVoice = false}) async {
    final client = widget.client;
    if (_dictatingOnPhone) {
      await _finishPhoneDictation();
      return;
    }
    if (client.daemonState == DaemonState.recording) {
      // dettatura del PC in corso: la ferma come sempre
      byVoice ? client.pressButtonByVoice(button.id) : client.pressButton(button.id);
      return;
    }
    if (!_phoneShouldTranscribe) {
      byVoice ? client.pressButtonByVoice(button.id) : client.pressButton(button.id);
      return;
    }
    setState(() => _dictatingOnPhone = true);
    client.pressButtonTranscribedByPhone(button.id, byVoice: byVoice);
    await _wakeWord.startCollecting();
  }

  /// Chiude la dettatura trascritta dal telefono e consegna il testo al PC,
  /// che lo incolla come se l'avesse trascritto lui.
  Future<void> _finishPhoneDictation() async {
    if (!_dictatingOnPhone) return;
    setState(() => _dictatingOnPhone = false);
    final testo = await _wakeWord.stopCollecting();
    widget.client.sendDictatedText(testo);
  }

  Future<void> _showAddButtonDialog(Dashboard dashboard, int row, int col) async {
    final labelController = TextEditingController();
    final comboController = TextEditingController();
    final combosController = TextEditingController();
    final delayController = TextEditingController(text: '120');
    final textController = TextEditingController();
    String kind = 'keys';
    LaunchableApp? selectedApp;

    // l'elenco delle app arriva dal PC su richiesta: si chiede subito, cosi'
    // e' gia' pronto se l'utente sceglie "Avvia applicazione"
    widget.client.requestApps();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_s.newButtonTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: kind,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: _s.buttonTypeLabel,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    _kindItem('keys', Icons.keyboard, _s.shortcutOption),
                    _kindItem('macro', Icons.playlist_play, _s.macroOption),
                    _kindItem('text', Icons.text_snippet, _s.textOption),
                    _kindItem('launch', Icons.rocket_launch, _s.launchOption),
                    _kindItem(
                      'paste_last',
                      Icons.content_paste,
                      _s.pasteLastOption,
                    ),
                    _kindItem('record', Icons.mic, _s.microphoneOption),
                    _kindItem(
                      'ai_command',
                      Icons.smart_toy,
                      _s.aiCommandOption,
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() {
                      kind = value;
                      if (labelController.text.isEmpty) {
                        if (kind == 'record') {
                          labelController.text = 'Registra';
                        } else if (kind == 'ai_command') {
                          labelController.text = 'Comando vocale';
                        } else if (kind == 'paste_last') {
                          labelController.text = _s.pasteLastDefaultLabel;
                        }
                      }
                    });
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: labelController,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: _s.labelField,
                    hintText: 'Copia',
                  ),
                ),
                if (kind == 'keys') ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: comboController,
                    decoration: InputDecoration(
                      labelText: _s.keyComboField,
                      hintText: 'ctrl+c',
                    ),
                  ),
                ],
                if (kind == 'macro') ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: combosController,
                    minLines: 3,
                    maxLines: 6,
                    decoration: InputDecoration(
                      labelText: _s.macroCombosField,
                      hintText: 'ctrl+s\nalt+tab\nctrl+v',
                      helperText: _s.macroCombosHelper,
                      helperMaxLines: 3,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: delayController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: _s.macroDelayField,
                    ),
                  ),
                ],
                if (kind == 'text') ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: textController,
                    minLines: 3,
                    maxLines: 8,
                    decoration: InputDecoration(
                      labelText: _s.textToPasteField,
                    ),
                  ),
                ],
                if (kind == 'paste_last') ...[
                  const SizedBox(height: 12),
                  Text(
                    _s.pasteLastHelper,
                    style: const TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                ],
                if (kind == 'launch') ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.apps),
                    label: Text(
                      selectedApp?.name ?? _s.chooseAppLabel,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: () async {
                      final app = await _showAppPicker();
                      if (app == null) return;
                      setDialogState(() {
                        selectedApp = app;
                        if (labelController.text.trim().isEmpty) {
                          labelController.text = app.name;
                        }
                      });
                    },
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_s.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_s.create),
            ),
          ],
        ),
      ),
    );
    if (result != true || labelController.text.trim().isEmpty) return;
    final label = labelController.text.trim();
    switch (kind) {
      case 'record':
      case 'ai_command':
      case 'paste_last':
        widget.client.addButton(
          dashboardId: dashboard.id,
          label: label,
          kind: kind,
          row: row,
          col: col,
        );
        break;
      case 'macro':
        final combos = combosController.text
            .split('\n')
            .map((c) => c.trim())
            .where((c) => c.isNotEmpty)
            .toList();
        if (combos.isEmpty) return;
        widget.client.addButton(
          dashboardId: dashboard.id,
          label: label,
          kind: 'macro',
          combos: combos,
          delayMs: int.tryParse(delayController.text.trim()),
          row: row,
          col: col,
        );
        break;
      case 'text':
        if (textController.text.trim().isEmpty) return;
        widget.client.addButton(
          dashboardId: dashboard.id,
          label: label,
          kind: 'text',
          text: textController.text,
          row: row,
          col: col,
        );
        break;
      case 'launch':
        final app = selectedApp;
        if (app == null) return;
        widget.client.addButton(
          dashboardId: dashboard.id,
          label: label,
          kind: 'launch',
          appId: app.id,
          row: row,
          col: col,
        );
        break;
      default:
        if (comboController.text.trim().isEmpty) return;
        widget.client.addButton(
          dashboardId: dashboard.id,
          label: label,
          combo: comboController.text.trim(),
          row: row,
          col: col,
        );
    }
  }

  DropdownMenuItem<String> _kindItem(
    String value,
    IconData icon,
    String label,
  ) {
    return DropdownMenuItem(
      value: value,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          // su schermi stretti le voci lunghe ("Incolla ultima dettatura")
          // non devono sfondare la riga del menu
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  /// Elenco filtrabile delle applicazioni installate sul PC. L'id vero
  /// (percorso .desktop, AppID...) non viene mai mostrato ne' digitato: si
  /// sceglie per nome dall'elenco che manda il demone.
  Future<LaunchableApp?> _showAppPicker() async {
    final searchController = TextEditingController();
    return showDialog<LaunchableApp>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(_s.chooseAppLabel),
            content: SizedBox(
              width: double.maxFinite,
              height: 420,
              // ListenableBuilder: l'elenco arriva dal PC dopo l'apertura
              // del dialogo, quindi la lista va ridisegnata quando il client
              // lo riceve, non solo quando si digita nella ricerca
              child: ListenableBuilder(
                listenable: widget.client,
                builder: (context, _) {
                  final query = searchController.text.trim().toLowerCase();
                  final apps = widget.client.apps
                      .where((a) => a.name.toLowerCase().contains(query))
                      .toList();
                  return Column(
                    children: [
                      TextField(
                        controller: searchController,
                        autofocus: true,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search),
                          hintText: _s.searchAppHint,
                        ),
                        onChanged: (_) => setDialogState(() {}),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: widget.client.apps.isEmpty
                            ? Center(child: Text(_s.loadingApps))
                            : apps.isEmpty
                                ? Center(child: Text(_s.noAppsFound))
                                : ListView.builder(
                                    itemCount: apps.length,
                                    itemBuilder: (context, index) => ListTile(
                                      dense: true,
                                      title: Text(apps[index].name),
                                      onTap: () => Navigator.of(
                                        context,
                                      ).pop(apps[index]),
                                    ),
                                  ),
                      ),
                    ],
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(_s.cancel),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showRemoveButtonDialog(ButtonSpec button) async {
    final description = button.isMic
        ? '"${button.label}" (${_s.microphoneParen})'
        : '"${button.label}" (${button.actionSummary})';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_s.removeButtonTitle),
        content: Text(_s.removeButtonBody(description)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_s.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_s.remove),
          ),
        ],
      ),
    );
    if (confirm == true) {
      widget.client.removeButton(button.id);
    }
  }

  Future<void> _showAddDashboardDialog() async {
    final nameController = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_s.newDashboard),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: _s.nameField,
            hintText: 'InvokeAI',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_s.create),
          ),
        ],
      ),
    );
    if (result == true && nameController.text.trim().isNotEmpty) {
      widget.client.createDashboard(nameController.text.trim());
    }
  }

  Future<void> _showDashboardOptionsDialog(Dashboard dashboard) async {
    final dashboards = _pageDashboards;
    final canDelete = dashboards.length > 1;
    final index = dashboards.indexWhere((d) => d.id == dashboard.id);

    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(dashboard.name),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: _s.moveLeft,
              onPressed: index > 0
                  ? () => Navigator.of(context).pop('move_left')
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: _s.moveRight,
              onPressed: index < dashboards.length - 1
                  ? () => Navigator.of(context).pop('move_right')
                  : null,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('settings'),
            child: Text(_s.settings),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('duplicate'),
            child: Text(_s.duplicate),
          ),
          TextButton(
            onPressed: canDelete
                ? () => Navigator.of(context).pop('delete')
                : null,
            child: Text(_s.delete),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(_s.close),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'move_left') {
      widget.client.reorderDashboard(dashboard.id, index - 1);
    } else if (choice == 'move_right') {
      widget.client.reorderDashboard(dashboard.id, index + 1);
    } else if (choice == 'duplicate') {
      widget.client.duplicateDashboard(dashboard.id);
    } else if (choice == 'settings') {
      final nameController = TextEditingController(text: dashboard.name);
      final matchController = TextEditingController(text: dashboard.match);
      final vocabularyController = TextEditingController(
        text: dashboard.vocabulary,
      );
      final result = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_s.dashboardSettingsTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: InputDecoration(labelText: _s.nameField),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: matchController,
                  decoration: InputDecoration(
                    labelText: _s.detectAppField,
                    hintText: 'es. "code" per Visual Studio Code',
                    helperText: _s.detectAppHelper,
                    helperMaxLines: 3,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: vocabularyController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: _s.dashboardVocabularyField,
                    hintText: 'InvokeAI, denoising, checkpoint',
                    helperText: _s.dashboardVocabularyHelper,
                    helperMaxLines: 3,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_s.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_s.save),
            ),
          ],
        ),
      );
      if (result == true) {
        if (nameController.text.trim().isNotEmpty) {
          widget.client.renameDashboard(
            dashboard.id,
            nameController.text.trim(),
          );
        }
        if (matchController.text.trim() != dashboard.match) {
          widget.client.setDashboardMatch(
            dashboard.id,
            matchController.text.trim(),
          );
        }
        if (vocabularyController.text.trim() != dashboard.vocabulary) {
          widget.client.setDashboardVocabulary(
            dashboard.id,
            vocabularyController.text.trim(),
          );
        }
      }
    } else if (choice == 'delete') {
      widget.client.removeDashboard(dashboard.id);
    }
  }

  void _changeRows(Dashboard dashboard, int delta) {
    final newRows = dashboard.rows + delta;
    if (newRows < 1) return;
    widget.client.setGridSize(dashboard.id, newRows, dashboard.cols);
  }

  void _changeCols(Dashboard dashboard, int delta) {
    final newCols = dashboard.cols + delta;
    if (newCols < 1) return;
    widget.client.setGridSize(dashboard.id, dashboard.rows, newCols);
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    final connected = client.status == ConnectionStatus.connected;
    final dashboards = _pageDashboards;
    final pageCount = dashboards.length + (_editMode ? 1 : 0);

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            if (!connected || dashboards.isEmpty)
              Positioned.fill(child: _buildDisconnectedView(client))
            else
              Positioned.fill(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: pageCount,
                  onPageChanged: (i) => setState(() => _currentPage = i),
                  itemBuilder: (context, index) {
                    if (index >= dashboards.length) {
                      return _buildAddDashboardPage();
                    }
                    return _buildDashboardPage(dashboards[index]);
                  },
                ),
              ),
            if (connected && dashboards.isNotEmpty)
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: _editMode && _currentPage < dashboards.length
                          ? () => _showDashboardOptionsDialog(
                              dashboards[_currentPage],
                            )
                          : null,
                      child: Text(
                        _currentPage < dashboards.length
                            ? dashboards[_currentPage].name
                            : _s.newDashboard,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    if (pageCount > 1) ...[
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < pageCount; i++)
                            Container(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i == _currentPage
                                    ? Colors.white
                                    : Colors.white30,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            Positioned(
              top: 8,
              left: 8,
              child: Column(
                children: [
                  IconButton(
                    icon: Icon(
                      _editMode ? Icons.done : Icons.edit_outlined,
                      color: Colors.white70,
                    ),
                    tooltip: _editMode ? _s.editModeOn : _s.editModeOff,
                    onPressed: () => setState(() => _editMode = !_editMode),
                  ),
                  // in modalita' modifica: crea una dashboard senza dover
                  // scoprire da soli che c'e' una pagina "+" in fondo allo
                  // swipe (vedi _buildAddDashboardPage)
                  if (_editMode)
                    IconButton(
                      icon: const Icon(
                        Icons.add_box_outlined,
                        color: Colors.white70,
                      ),
                      tooltip: _s.newDashboard,
                      onPressed: _showAddDashboardDialog,
                    ),
                  IconButton(
                    icon: Icon(
                      Icons.center_focus_strong,
                      color: _followActiveApp
                          ? Colors.lightBlueAccent
                          : Colors.white38,
                    ),
                    tooltip: _followActiveApp
                        ? _s.followActiveAppOn
                        : _s.followActiveAppOff,
                    onPressed: _toggleFollowActiveApp,
                  ),
                  if (client.history.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.history, color: Colors.white38),
                      tooltip: _s.historyTooltip,
                      onPressed: _openHistoryScreen,
                    ),
                  // l'ascolto della frase di attivazione non si vede da
                  // nessun'altra parte: senza una spia, un microfono aperto
                  // resterebbe acceso senza che l'utente lo sappia
                  if (_phoneWakeWord || client.wakeWordEnabled)
                    IconButton(
                      icon: Icon(
                        Icons.hearing,
                        color: _wakeWord.listening || client.wakeWordEnabled
                            ? Colors.lightBlueAccent
                            : Colors.white38,
                      ),
                      tooltip: _s.wakeWordListeningNow,
                      onPressed: _openSettings,
                    ),
                ],
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Column(
                // le pillole dei video sono piu' larghe dell'ingranaggio:
                // vanno allineate al bordo destro, non centrate su di esso
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(Icons.settings, color: Colors.white70),
                    onPressed: _openSettings,
                  ),
                  if (connected) ..._buildMediaPlayerButtons(client),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDashboardPage(Dashboard dashboard) {
    // in landscape, fuori dalla modalita' modifica, i pulsanti vengono
    // ridisposti su una griglia piu' compatta a 3 colonne (vedi
    // _buildLandscapeReflow) invece della griglia riga/colonna usata per
    // l'editing, che in orizzontale risulterebbe con celle strette e
    // allungate. La griglia riga/colonna resta l'unica usata per l'editing
    // (tocca una cella precisa per aggiungere/spostare un pulsante), quindi
    // torna visibile entrando in modalita' modifica anche in landscape.
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    if (!_editMode && isLandscape) {
      // una dashboard a una sola colonna (es. quella con solo "Registra")
      // e' pensata per il ritratto: la griglia a 3 colonne fissa di
      // _buildLandscapeReflow lascerebbe gran parte della larghezza vuota
      // per cosi' pochi pulsanti. Qui si dividono invece in una singola
      // riga che occupa tutto lo schermo (vedi _buildLandscapeSingleColumn).
      if (dashboard.cols == 1) {
        return _buildLandscapeSingleColumn(dashboard);
      }
      return _buildLandscapeReflow(dashboard);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Row(
        children: [
          Expanded(
            child: Column(
              children: [
                Expanded(child: _buildGrid(dashboard)),
                if (_editMode) _buildRowResizeBar(dashboard),
              ],
            ),
          ),
          if (_editMode) _buildColResizeBar(dashboard),
        ],
      ),
    );
  }

  /// La griglia vera e propria. Non e' una tabella di righe e colonne: ogni
  /// pulsante viene posizionato e dimensionato sulla misura della cella,
  /// perche' puo' occuparne piu' d'una (vedi [ButtonSpec.rowSpan]). Le celle
  /// libere restano disegnate una per una, cosi' in modalita' modifica si
  /// puo' toccare o trascinare esattamente il posto voluto.
  Widget _buildGrid(Dashboard dashboard) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellWidth = constraints.maxWidth / dashboard.cols;
        final cellHeight = constraints.maxHeight / dashboard.rows;
        return Stack(
          // senza questo lo Stack si dimensionerebbe sui figli NON
          // posizionati — che qui non ci sono — collassando a zero: le celle
          // resterebbero visibili (disegnate oltre i limiti) ma fuori
          // dall'area che riceve i tocchi
          fit: StackFit.expand,
          children: [
            _buildDashboardBackdrop(dashboard),
            for (var row = 0; row < dashboard.rows; row++)
              for (var col = 0; col < dashboard.cols; col++)
                if (dashboard.covering(row, col) == null)
                  Positioned(
                    left: col * cellWidth,
                    top: row * cellHeight,
                    width: cellWidth,
                    height: cellHeight,
                    child: _buildCell(dashboard, row, col, null),
                  ),
            for (final button in dashboard.buttons)
              Positioned(
                left: button.col * cellWidth,
                top: button.row * cellHeight,
                width: cellWidth * button.colSpan,
                height: cellHeight * button.rowSpan,
                child: _buildCell(dashboard, button.row, button.col, button),
              ),
          ],
        );
      },
    );
  }

  /// Dashboard a una sola colonna (quindi pensata per il ritratto, dove i
  /// pulsanti riempiono tutta la larghezza uno sopra l'altro) vista in
  /// landscape: qui vengono disposti in un'unica riga che occupa tutto lo
  /// schermo, nello stesso ordine dall'alto in basso, dividendo lo spazio
  /// in parti uguali per numero di elementi — l'equivalente orizzontale
  /// della colonna verticale originale, invece di lasciare gran parte
  /// della larghezza inutilizzata.
  Widget _buildLandscapeSingleColumn(Dashboard dashboard) {
    final buttons = [...dashboard.buttons]..sort((a, b) => a.row.compareTo(b.row));
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Row(
        children: [
          for (final button in buttons)
            Expanded(
              child: _buildCell(dashboard, button.row, button.col, button),
            ),
        ],
      ),
    );
  }

  /// Ridispone i pulsanti della dashboard (celle vuote escluse) in ordine
  /// di lettura su una griglia fissa a 3 colonne, piu' comoda da premere in
  /// landscape rispetto alla griglia riga/colonna originale. Scorrevole:
  /// a differenza della griglia di editing (che riempie esattamente lo
  /// schermo comprimendo le celle), qui una dashboard con molti pulsanti
  /// resta leggibile invece di rimpicciolirsi oltre misura.
  Widget _buildLandscapeReflow(Dashboard dashboard) {
    final buttons = [...dashboard.buttons]..sort((a, b) {
      final byRow = a.row.compareTo(b.row);
      return byRow != 0 ? byRow : a.col.compareTo(b.col);
    });
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: GridView.builder(
        padding: const EdgeInsets.all(4),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 2,
        ),
        itemCount: buttons.length,
        itemBuilder: (context, index) {
          final button = buttons[index];
          return _buildCell(dashboard, button.row, button.col, button);
        },
      ),
    );
  }

  /// Un pulsante play/pausa per ogni video che il PC sta esponendo, anche
  /// se fermo: serve a fermare un video prima di dettare senza tornare alla
  /// tastiera, e a farlo ripartire dopo. Piu' piccoli dei comandi
  /// principali, perche' sono controlli occasionali e non devono rubare
  /// spazio alla griglia.
  List<Widget> _buildMediaPlayerButtons(StenoClient client) {
    // oltre un certo numero la colonna scenderebbe sopra i pulsanti: chi ha
    // dieci schede che suonano insieme ha un problema diverso
    final players = client.players.take(_maxMediaPlayerButtons);
    return [
      for (final player in players)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: GestureDetector(
            onTap: () =>
                client.setMediaPlayerPlaying(player.id, !player.playing),
            behavior: HitTestBehavior.opaque,
            child: Tooltip(
              message: player.playing
                  ? _s.pauseMediaTooltip(player.label)
                  : _s.playMediaTooltip(player.label),
              child: Container(
                // fondo scuro: il titolo scorre sopra le celle colorate
                // della griglia, e senza sarebbe illeggibile su quelle
                // chiare
                decoration: BoxDecoration(
                  color: Colors.black38,
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.fromLTRB(10, 3, 4, 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // il titolo sta a sinistra dell'icona e non oltre meta'
                    // schermo: deve bastare a riconoscere il video senza
                    // coprire la griglia sotto
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * 0.45,
                      ),
                      child: Text(
                        player.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: player.playing
                              ? Colors.white70
                              : Colors.white38,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      player.playing
                          ? Icons.pause_circle_outline
                          : Icons.play_circle_outline,
                      size: 26,
                      color: player.playing ? Colors.white70 : Colors.white38,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _buildAddDashboardPage() {
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: GestureDetector(
        onTap: _showAddDashboardDialog,
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: Colors.black26,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.add_box_outlined,
                  size: 64,
                  color: Colors.white38,
                ),
                const SizedBox(height: 12),
                Text(
                  _s.newDashboard,
                  style: const TextStyle(color: Colors.white38, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRowResizeBar(Dashboard dashboard) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.remove_circle_outline),
          tooltip: _s.removeRow,
          onPressed: () => _changeRows(dashboard, -1),
        ),
        Text(_s.rowsLabel),
        IconButton(
          icon: const Icon(Icons.add_circle_outline),
          tooltip: _s.addRow,
          onPressed: () => _changeRows(dashboard, 1),
        ),
      ],
    );
  }

  Widget _buildColResizeBar(Dashboard dashboard) {
    return RotatedBox(
      quarterTurns: 1,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            tooltip: _s.removeColumn,
            onPressed: () => _changeCols(dashboard, -1),
          ),
          Text(_s.colsLabel),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: _s.addColumn,
            onPressed: () => _changeCols(dashboard, 1),
          ),
        ],
      ),
    );
  }

  Widget _buildDisconnectedView(StenoClient client) {
    final visuals = _visualsForDisconnected(client);
    return GestureDetector(
      onTap: _openSettings,
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: visuals.color,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(visuals.icon, size: 96, color: Colors.white),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  visuals.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCell(Dashboard dashboard, int row, int col, ButtonSpec? button) {
    final Widget content;
    if (button == null) {
      content = GestureDetector(
        onTap: () => _handleCellTap(dashboard, row, col, null),
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.all(2),
          decoration: _editMode
              ? BoxDecoration(
                  border: Border.all(color: Colors.white24),
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          child: _editMode
              ? const Center(
                  child: Icon(Icons.add, color: Colors.white24, size: 32),
                )
              : null,
        ),
      );
    } else if (button.isRecord) {
      content = _buildRecordCell(dashboard, row, col, button);
    } else if (button.isAiCommand) {
      content = _buildAiCommandCell(dashboard, row, col, button);
    } else {
      content = _buildKeysCell(dashboard, row, col, button);
    }

    if (!_editMode) return content;

    // In modalita' modifica ogni cella e' anche una destinazione valida per
    // trascinare una scorciatoia da un'altra cella (vedi maniglia di
    // trascinamento in _buildKeysCell). Il demone rifiuta comunque lo
    // spostamento se la cella e' gia' occupata.
    return DragTarget<String>(
      onAcceptWithDetails: (details) =>
          widget.client.moveButton(details.data, row, col),
      builder: (context, candidateData, rejectedData) {
        return Stack(
          fit: StackFit.expand,
          children: [
            content,
            if (candidateData.isNotEmpty)
              IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white, width: 2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildRecordCell(
    Dashboard dashboard,
    int row,
    int col,
    ButtonSpec button,
  ) => _buildMicCell(dashboard, row, col, button, kind: 'record');

  Widget _buildAiCommandCell(
    Dashboard dashboard,
    int row,
    int col,
    ButtonSpec button,
  ) => _buildMicCell(dashboard, row, col, button, kind: 'ai_command');

  /// Cella condivisa dai pulsanti "microfono" (kind "record" e
  /// "ai_command"): stessa struttura (icona/etichetta secondo lo stato, X
  /// per rimuovere, intera cella trascinabile in modalita' modifica), solo
  /// l'aspetto a riposo cambia in base al tipo.
  Widget _buildMicCell(
    Dashboard dashboard,
    int row,
    int col,
    ButtonSpec button, {
    required String kind,
  }) {
    final client = widget.client;
    // mentre un altro microfono tiene la sessione questo resta inerte e
    // sbiadito: la dettatura in corso appartiene all'altro pulsante
    final locked = !_editMode && _isMicLocked(button);
    final visuals = locked
        ? _visualsForLockedMic(kind: kind)
        : _visualsForMic(client, kind: kind);
    // push-to-talk: la registrazione dura quanto la pressione. Sospeso in
    // modalita' modifica, dove il tocco serve a selezionare/trascinare il
    // pulsante e non a dettare.
    final holdToTalk = _pushToTalk && !_editMode;

    final cell = GestureDetector(
      onTap: (holdToTalk || locked)
          ? null
          : () => _handleCellTap(dashboard, row, col, button),
      onTapDown: (holdToTalk && !locked)
          ? (_) {
              if (client.status != ConnectionStatus.connected) return;
              if (!_daemonBusy) _claimMicSession(button);
              client.pressButtonDown(button.id);
            }
          : null,
      onTapUp: (holdToTalk && !locked)
          ? (_) => client.pressButtonUp(button.id)
          : null,
      // il rilascio va inviato anche quando il tocco viene annullato (dito
      // trascinato fuori dalla cella): altrimenti resterebbe a registrare
      onTapCancel: (holdToTalk && !locked)
          ? () => client.pressButtonUp(button.id)
          : null,
      // anche un microfono si rinomina e si ingrandisce: l'editor si apre
      // con la stessa pressione prolungata degli altri pulsanti, ma senza
      // colore e icona (il suo aspetto segue lo stato della registrazione)
      onLongPress: _editMode
          ? () => _showButtonStyleDialog(dashboard, button)
          : null,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            margin: const EdgeInsets.all(2),
            width: double.infinity,
            height: double.infinity,
            color: visuals.color,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      visuals.icon,
                      size: 64,
                      color: locked ? Colors.white38 : Colors.white,
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        visuals.label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 18,
                          color: locked ? Colors.white38 : Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // invio automatico: la spunta sta sul pulsante e non nelle
          // impostazioni perche' si accende e si spegne di continuo — in
          // chat serve, in un editor no. Solo sulla dettatura normale: il
          // comando vocale IA non incolla testo.
          if (button.isRecord && !locked)
            Positioned(
              bottom: 4,
              right: 4,
              child: GestureDetector(
                onTap: () => client.editButton(
                  button.id,
                  autoEnter: !button.autoEnter,
                ),
                behavior: HitTestBehavior.opaque,
                child: Tooltip(
                  message: button.autoEnter
                      ? _s.autoEnterOn
                      : _s.autoEnterOff,
                  child: Container(
                    // fondo scuro: la spunta sta sopra il colore della
                    // cella, che cambia con lo stato della registrazione
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.fromLTRB(8, 2, 4, 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // l'etichetta dice cosa fa la spunta: il tooltip da
                        // solo richiederebbe di tenerla premuta per scoprirlo
                        Text(
                          _s.autoEnterLabel,
                          style: TextStyle(
                            fontSize: 11,
                            color: button.autoEnter
                                ? Colors.white
                                : Colors.white38,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          button.autoEnter
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          color: button.autoEnter
                              ? Colors.white
                              : Colors.white38,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (_editMode)
            Positioned(
              top: 6,
              right: 6,
              child: GestureDetector(
                onTap: () => _showRemoveButtonDialog(button),
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.close, color: Colors.white70, size: 20),
                ),
              ),
            ),
        ],
      ),
    );

    if (!_editMode) return cell;

    // in modalita' modifica l'intera cella (non solo un'iconcina) e'
    // trascinabile per riposizionarla in un'altra cella della griglia
    return Draggable<String>(
      data: button.id,
      feedback: Material(
        color: Colors.transparent,
        child: Icon(visuals.icon, color: Colors.white, size: 56),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: cell),
      child: cell,
    );
  }

  /// Sfondo della dashboard: l'icona dell'applicazione a cui e' dedicata,
  /// grande al centro dello schermo, con un alone di luce che la stacca dal
  /// fondo nero. Sta sotto la griglia e si intravede appena fra un pulsante
  /// e l'altro — deve abbellire, non competere con le etichette.
  Widget _buildDashboardBackdrop(Dashboard dashboard) {
    final icon = _appIconFor(dashboard.appId);
    if (icon == null) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: FractionallySizedBox(
            widthFactor: 0.62,
            heightFactor: 0.62,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // alone: un bagliore diffuso del colore dominante non si puo'
                // calcolare senza decodificare l'immagine, ma un bianco molto
                // tenue sotto l'icona da' lo stesso effetto di luce diffusa
                // su qualunque logo
                DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0.22),
                        Colors.white.withValues(alpha: 0.08),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                  child: const SizedBox.expand(),
                ),
                Opacity(
                  opacity: 0.62,
                  child: Image.memory(
                    icon,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                    gaplessPlayback: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Icona dell'applicazione da mostrare dietro un pulsante, chiedendola al
  /// PC la prima volta che serve. `null` finche' non e' arrivata, o per
  /// sempre se quell'app non ne ha una: in quel caso il pulsante resta a
  /// tinta piena.
  Uint8List? _appIconFor(String? appId) {
    if (appId == null) return null;
    final client = widget.client;
    if (!client.appIcons.containsKey(appId)) {
      // fuori dal build: chiedere durante la costruzione dell'albero
      // significherebbe notificare i listener mentre si sta gia' disegnando
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => client.requestAppIcon(appId),
      );
      return null;
    }
    return client.appIcons[appId];
  }

  /// Icona mostrata dentro un pulsante. Per chi avvia un'applicazione e'
  /// quella vera dell'app, che si riconosce a colpo d'occhio meglio di
  /// qualunque simbolo generico; si ripiega sull'icona a razzo finche' non
  /// e' arrivata dal PC, se quell'applicazione non ne ha una, o se e' stata
  /// scelta un'icona a mano (in quel caso vince la scelta dell'utente).
  Widget _buttonIcon(ButtonSpec button, Color color) {
    if (button.isLaunch && button.icon == null) {
      final appIcon = _appIconFor(button.appId);
      if (appIcon != null) {
        return Image.memory(
          appIcon,
          width: 40,
          height: 40,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
        );
      }
    }
    return Icon(button.displayIcon, size: 36, color: color);
  }

  Widget _buildKeysCell(
    Dashboard dashboard,
    int row,
    int col,
    ButtonSpec button,
  ) {
    final flashing = _flashingButtonId == button.id;
    final baseColor = button.displayColor;
    final cellColor = flashing
        ? Color.lerp(baseColor, Colors.white, 0.35)!
        : baseColor;
    final onCellColor = contrastingOn(cellColor);

    final cell = GestureDetector(
      onTap: () => _handleCellTap(dashboard, row, col, button),
      onLongPress: _editMode
          ? () => _showButtonStyleDialog(dashboard, button)
          : null,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.all(2),
            width: double.infinity,
            height: double.infinity,
            // velo, non tinta piena: sotto la griglia c'e' l'icona
            // dell'applicazione (vedi _buildDashboardBackdrop), che deve
            // restare intuibile senza rendere illeggibili le etichette
            color: cellColor.withValues(alpha: _cellOpacity),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buttonIcon(button, onCellColor),
                    const SizedBox(height: 8),
                    Text(
                      button.label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: onCellColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_editMode)
            Positioned(
              top: 6,
              right: 6,
              child: GestureDetector(
                onTap: () => _showRemoveButtonDialog(button),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.close, color: onCellColor, size: 20),
                ),
              ),
            ),
        ],
      ),
    );

    if (!_editMode) return cell;

    // in modalita' modifica l'intera cella e' trascinabile per riposizionarla;
    // onLongPress (editor di stile) resta gestito dal GestureDetector interno
    // e coesiste con Draggable perche' quest'ultimo riconosce solo il pan
    return Draggable<String>(
      data: button.id,
      feedback: Material(
        color: Colors.transparent,
        child: Icon(button.displayIcon, color: Colors.white, size: 48),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: cell),
      child: cell,
    );
  }

  /// Di quante celle puo' crescere il pulsante in una direzione prima di
  /// incontrare un altro pulsante o il bordo della griglia. Serve a non far
  /// scegliere una dimensione che il PC rifiuterebbe: il "piu'" si spegne
  /// quando lo spazio finisce, invece di lasciar provare e poi dare errore.
  int _maxSpan(
    Dashboard dashboard,
    ButtonSpec button, {
    required bool horizontal,
    required int otherSpan,
  }) {
    var span = 1;
    while (span < _maxButtonSpan) {
      final next = (horizontal ? button.col : button.row) + span;
      if (next >= (horizontal ? dashboard.cols : dashboard.rows)) break;
      final from = horizontal ? button.row : button.col;
      var free = true;
      for (var i = from; i < from + otherSpan; i++) {
        final occupant = horizontal
            ? dashboard.covering(i, next)
            : dashboard.covering(next, i);
        if (occupant != null && occupant.id != button.id) {
          free = false;
          break;
        }
      }
      if (!free) break;
      span++;
    }
    return span;
  }

  /// Selettore "meno/piu'" per quante celle occupa un pulsante. Il limite
  /// superiore e' lo stesso del demone (BUTTON_MAX_SPAN): oltre, sarebbe
  /// comunque lui a rifiutare.
  Widget _spanStepper({
    required String label,
    required int value,
    required int max,
    required ValueChanged<int> onChanged,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: value > 1 ? () => onChanged(value - 1) : null,
            ),
            Text('$value', style: const TextStyle(fontSize: 16)),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_circle_outline),
              onPressed: value < max ? () => onChanged(value + 1) : null,
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showButtonStyleDialog(
    Dashboard dashboard,
    ButtonSpec button,
  ) async {
    String? selectedColor = button.color;
    String? selectedIcon = button.icon;
    int rowSpan = button.rowSpan;
    int colSpan = button.colSpan;
    // l'azione e' modificabile solo per i tipi che ne hanno una scritta:
    // "launch" (l'applicazione si sceglie dall'elenco) e i microfoni non
    // passano di qui
    final labelController = TextEditingController(text: button.label);
    final comboController = TextEditingController(text: button.combo ?? '');
    final combosController = TextEditingController(
      text: button.combos.join('\n'),
    );
    final delayController = TextEditingController(
      text: (button.delayMs ?? 120).toString(),
    );
    final textController = TextEditingController(text: button.text ?? '');

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_s.editButtonTitle(button.label)),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: labelController,
                  decoration: InputDecoration(labelText: _s.labelField),
                ),
                if (button.isKeys) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: comboController,
                    decoration: InputDecoration(
                      labelText: _s.keyComboField,
                      hintText: 'ctrl+c',
                    ),
                  ),
                ],
                if (button.isMacro) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: combosController,
                    minLines: 3,
                    maxLines: 6,
                    decoration: InputDecoration(
                      labelText: _s.macroCombosField,
                      hintText: 'ctrl+s\nalt+tab\nctrl+v',
                      helperText: _s.macroCombosHelper,
                      helperMaxLines: 3,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: delayController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: _s.macroDelayField),
                  ),
                ],
                if (button.isText) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: textController,
                    minLines: 3,
                    maxLines: 8,
                    decoration: InputDecoration(
                      labelText: _s.textToPasteField,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_s.sizeLabel),
                ),
                Builder(
                  builder: (context) {
                    // lo spazio libero dipende dall'altra dimensione: si
                    // ricalcola ad ogni tocco, non una volta sola
                    final maxCols = _maxSpan(
                      dashboard,
                      button,
                      horizontal: true,
                      otherSpan: rowSpan,
                    );
                    final maxRows = _maxSpan(
                      dashboard,
                      button,
                      horizontal: false,
                      otherSpan: colSpan,
                    );
                    return Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _spanStepper(
                                label: _s.widthLabel,
                                value: colSpan,
                                max: maxCols,
                                onChanged: (v) =>
                                    setDialogState(() => colSpan = v),
                              ),
                            ),
                            Expanded(
                              child: _spanStepper(
                                label: _s.heightLabel,
                                value: rowSpan,
                                max: maxRows,
                                onChanged: (v) =>
                                    setDialogState(() => rowSpan = v),
                              ),
                            ),
                          ],
                        ),
                        // senza celle libere attorno non c'e' verso di
                        // ingrandirlo: meglio dirlo qui che far scoprire il
                        // rifiuto dopo aver premuto Salva
                        if (maxCols == 1 && maxRows == 1)
                          Text(
                            _s.noRoomToGrow,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.orange,
                            ),
                          ),
                      ],
                    );
                  },
                ),
                if (!button.isMic) ...[
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_s.colorLabel),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final tint in buttonPalette)
                      GestureDetector(
                        onTap: () =>
                            setDialogState(() => selectedColor = tint.hex),
                        child: Tooltip(
                          message: tint.name,
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: tint.color,
                              shape: BoxShape.circle,
                              border: selectedColor == tint.hex
                                  ? Border.all(color: Colors.white, width: 3)
                                  : null,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_s.iconLabel),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 180,
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final entry in iconByName.entries)
                          GestureDetector(
                            onTap: () => setDialogState(
                              () => selectedIcon = entry.key,
                            ),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: selectedIcon == entry.key
                                    ? Colors.white24
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(entry.value, color: Colors.white),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                ],
              ],
            ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(_s.cancel),
            ),
            FilledButton(
              onPressed: () {
                _saveButtonEdits(
                  button,
                  label: labelController.text,
                  combo: comboController.text,
                  combos: combosController.text,
                  delay: delayController.text,
                  text: textController.text,
                  rowSpan: rowSpan,
                  colSpan: colSpan,
                );
                if (!button.isMic) {
                  widget.client.setButtonStyle(
                    button.id,
                    color: selectedColor,
                    icon: selectedIcon,
                  );
                }
                Navigator.of(context).pop();
              },
              child: Text(_s.save),
            ),
          ],
        ),
      ),
    );
  }

  /// Invia al demone le modifiche fatte nell'editor del pulsante (vedi
  /// [_showButtonStyleDialog]). Manda solo i campi che riguardano il tipo
  /// del pulsante e che sono davvero cambiati: il demone rifiuta un campo
  /// estraneo al tipo, e una modifica inutile farebbe comunque riscrivere
  /// e ritrasmettere l'intero layout.
  void _saveButtonEdits(
    ButtonSpec button, {
    required String label,
    required String combo,
    required String combos,
    required String delay,
    required String text,
    required int rowSpan,
    required int colSpan,
  }) {
    final newLabel = label.trim();
    final changedLabel = newLabel.isNotEmpty && newLabel != button.label;

    String? newCombo;
    if (button.isKeys) {
      final value = combo.trim();
      if (value.isNotEmpty && value != button.combo) newCombo = value;
    }

    List<String>? newCombos;
    int? newDelay;
    if (button.isMacro) {
      final steps = combos
          .split('\n')
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty)
          .toList();
      if (steps.isNotEmpty && !listEquals(steps, button.combos)) {
        newCombos = steps;
      }
      final parsed = int.tryParse(delay.trim());
      if (parsed != null && parsed != button.delayMs) newDelay = parsed;
    }

    String? newText;
    if (button.isText) {
      if (text.trim().isNotEmpty && text != button.text) newText = text;
    }

    final changedSize =
        rowSpan != button.rowSpan || colSpan != button.colSpan;

    if (!changedLabel &&
        !changedSize &&
        newCombo == null &&
        newCombos == null &&
        newDelay == null &&
        newText == null) {
      return;
    }
    widget.client.editButton(
      button.id,
      label: changedLabel ? newLabel : null,
      combo: newCombo,
      combos: newCombos,
      delayMs: newDelay,
      text: newText,
      // le due dimensioni viaggiano insieme: il demone le valida come
      // un'unica area, e mandarne una sola gli farebbe assumere l'altra
      rowSpan: changedSize ? rowSpan : null,
      colSpan: changedSize ? colSpan : null,
    );
  }

  /// Visuals condivisi dai pulsanti "microfono" (kind "record" e
  /// "ai_command"): lo stato della registrazione/trascrizione/elaborazione
  /// IA e' globale (un solo demone, una registrazione alla volta), solo
  /// l'aspetto a riposo (idle) distingue i due tipi.
  _Visuals _visualsForMic(StenoClient client, {required String kind}) {
    switch (client.daemonState) {
      case DaemonState.recording:
        return _Visuals(Colors.red.shade800, _s.recordingStopHint, Icons.mic);
      case DaemonState.transcribing:
        return _Visuals(
          Colors.amber.shade800,
          _s.transcribing,
          Icons.hourglass_top,
        );
      case DaemonState.thinking:
        return _Visuals(
          Colors.deepPurple.shade800,
          _s.aiThinking,
          Icons.psychology,
        );
      case DaemonState.loading:
        return _Visuals(
          Colors.cyan.shade800,
          _s.loadingModel,
          Icons.hourglass_empty,
        );
      case DaemonState.idle:
      case DaemonState.unknown:
        switch (kind) {
          case 'ai_command':
            return _Visuals(
              Colors.indigo.shade800,
              _s.tapForAiCommand,
              Icons.smart_toy,
            );
          default:
            return _Visuals(
              Colors.grey.shade800,
              _pushToTalk ? _s.pushToTalkHint : _s.tapToRecord,
              Icons.mic_none,
            );
        }
    }
  }

  /// Aspetto del microfono disabilitato perche' la sessione in corso e' di
  /// un altro microfono (vedi [_isMicLocked]): resta riconoscibile per
  /// tipo, ma spento, per far capire che non e' quello da toccare.
  _Visuals _visualsForLockedMic({required String kind}) {
    switch (kind) {
      case 'ai_command':
        return _Visuals(
          Colors.indigo.shade900.withValues(alpha: 0.45),
          _s.micBusyElsewhere,
          Icons.smart_toy,
        );
      default:
        return _Visuals(
          Colors.grey.shade900.withValues(alpha: 0.45),
          _s.micBusyElsewhere,
          Icons.mic_off,
        );
    }
  }

  _Visuals _visualsForDisconnected(StenoClient client) {
    switch (client.status) {
      case ConnectionStatus.connecting:
        return _Visuals(
          Colors.blueGrey.shade700,
          _s.connectingToPc,
          Icons.sync,
        );
      case ConnectionStatus.authFailed:
        // il demone spiega perche' ha rifiutato: mostrarlo evita di
        // mandare a caccia di un token sbagliato chi in realta' ha un
        // problema diverso (vedi "reason" in daemon.py)
        return _Visuals(
          Colors.grey.shade900,
          client.lastFailureReason ?? _s.invalidTokenCheckSettings,
          Icons.gpp_bad,
        );
      case ConnectionStatus.disconnected:
      case ConnectionStatus.error:
      case ConnectionStatus.connected:
        return _Visuals(
          Colors.grey.shade900,
          client.lastFailureReason ?? _s.notConnectedTapForSettings,
          Icons.link_off,
        );
    }
  }
}

class _Visuals {
  const _Visuals(this.color, this.label, this.icon);

  final Color color;
  final String label;
  final IconData icon;
}
