import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/connection_settings.dart';
import '../models/daemon_state.dart';
import '../services/locale_service.dart';
import '../services/settings_service.dart';
import '../services/steno_client.dart';
import '../services/wake_phrase.dart';
import '../services/wake_word_service.dart';

/// Lingue di dettatura comuni (stessa lista di SUPPORTED_LANGUAGES in
/// daemon.py). I nomi restano in italiano indipendentemente dalla lingua
/// dell'interfaccia: tradurre ~20 nomi di lingua in piu' lingue non vale la
/// complessita' aggiuntiva per un elenco puramente informativo.
const Map<String, String> dictationLanguages = {
  'auto': 'Rilevamento automatico',
  'it': 'Italiano',
  'en': 'Inglese',
  'es': 'Spagnolo',
  'fr': 'Francese',
  'de': 'Tedesco',
  'pt': 'Portoghese',
  'nl': 'Olandese',
  'ru': 'Russo',
  'zh': 'Cinese',
  'ja': 'Giapponese',
  'ko': 'Coreano',
  'ar': 'Arabo',
  'hi': 'Hindi',
  'pl': 'Polacco',
  'tr': 'Turco',
  'sv': 'Svedese',
  'el': 'Greco',
  'cs': 'Ceco',
  'ro': 'Rumeno',
  'uk': 'Ucraino',
};

/// Lingue selezionabili come destinazione della traduzione automatica:
/// stesso elenco di [dictationLanguages] ma senza "auto" (bisogna sapere
/// verso quale lingua tradurre, vedi set_translate_target in daemon.py).
final Map<String, String> translateTargetLanguages = {
  for (final entry in dictationLanguages.entries)
    if (entry.key != 'auto') entry.key: entry.value,
};

/// Attese selezionabili prima che la dettatura si chiuda da sola (0 = mai).
/// Sono valori tondi dentro l'intervallo accettato dal demone (vedi
/// SILENCE_TIMEOUT_MIN/MAX in daemon.py): sotto i 3 secondi una pausa per
/// riprendere fiato basterebbe a chiudere la dettatura.
const List<int> _silenceChoices = [0, 5, 10, 15, 20, 30, 60];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.client,
    required this.locale,
    this.wakeWord,
  });

  final StenoClient client;
  final LocaleService locale;

  /// Ascolto della frase di attivazione sul telefono: serve solo a mostrare
  /// cosa ha sentito il riconoscitore (vedi WakeWordService.lastHeard). Puo'
  /// mancare, ad esempio nei test della schermata.
  final WakeWordService? wakeWord;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settingsService = SettingsService();
  final _hostController = TextEditingController();
  final _portController = TextEditingController(
    text: '${SettingsService.defaultPort}',
  );
  final _tokenController = TextEditingController();

  final _vocabularyController = TextEditingController();
  final _wakeStartController = TextEditingController();
  final _wakeStopController = TextEditingController();

  bool _obscureToken = true;
  bool _testing = false;
  String? _testResult;
  bool _loaded = false;
  bool _pushToTalk = false;
  bool _haptics = true;
  bool _phoneWakeWord = false;
  bool _phoneMicrophone = false;
  bool _silenceBeeps = true;
  String? _wakeStartError;
  String? _wakeStopError;
  /// versione della configurazione gia' riportata nel campo vocabolario:
  /// evita di sovrascrivere quello che l'utente sta scrivendo ad ogni
  /// aggiornamento inviato dal demone
  int _vocabularyConfigVersion = -1;
  /// stesso ruolo di [_vocabularyConfigVersion] per le frasi di attivazione
  int _wakePhrasesConfigVersion = -1;
  /// ultime impostazioni di connessione gia' salvate/applicate: evita di
  /// riconnettersi inutilmente (con relativo sfarfallio dello stato) quando
  /// l'utente tocca fuori da un campo senza averlo davvero modificato
  ConnectionSettings? _lastAppliedSettings;

  @override
  void initState() {
    super.initState();
    widget.locale.addListener(_onChanged);
    widget.client.addListener(_onChanged);
    // aggiorna il riquadro con l'ultima frase sentita mentre l'utente guarda
    widget.wakeWord?.addListener(_onChanged);
    _load();
  }

  @override
  void dispose() {
    widget.locale.removeListener(_onChanged);
    widget.client.removeListener(_onChanged);
    widget.wakeWord?.removeListener(_onChanged);
    _hostController.dispose();
    _portController.dispose();
    _tokenController.dispose();
    _vocabularyController.dispose();
    _wakeStartController.dispose();
    _wakeStopController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final settings = await _settingsService.load();
    _hostController.text = settings.host;
    _portController.text = '${settings.port}';
    _tokenController.text = settings.token;
    _lastAppliedSettings = settings;
    final pushToTalk = await _settingsService.loadPushToTalk();
    final haptics = await _settingsService.loadHapticFeedback();
    final phoneWakeWord = await _settingsService.loadPhoneWakeWord();
    final phoneMicrophone = await _settingsService.loadPhoneMicrophone();
    final silenceBeeps = await _settingsService.loadSilenceBeeps();
    if (mounted) {
      setState(() {
        _pushToTalk = pushToTalk;
        _haptics = haptics;
        _phoneWakeWord = phoneWakeWord;
        _phoneMicrophone = phoneMicrophone;
        _silenceBeeps = silenceBeeps;
        _loaded = true;
      });
    }
  }

  /// Allinea il campo vocabolario a quello del demone solo quando arriva
  /// davvero una configurazione nuova, non ad ogni ricostruzione: altrimenti
  /// il testo che l'utente sta digitando verrebbe riscritto sotto le dita.
  void _syncVocabularyField() {
    if (_vocabularyConfigVersion == widget.client.configVersion) return;
    _vocabularyConfigVersion = widget.client.configVersion;
    _vocabularyController.text = widget.client.vocabulary;
  }

  /// Come [_syncVocabularyField], per le due frasi di attivazione.
  void _syncWakePhraseFields() {
    if (_wakePhrasesConfigVersion == widget.client.configVersion) return;
    _wakePhrasesConfigVersion = widget.client.configVersion;
    _wakeStartController.text = widget.client.wakePhraseStart;
    _wakeStopController.text = widget.client.wakePhraseStop;
  }

  /// Manda al demone la frase appena scritta, se e' valida. I controlli sono
  /// gli stessi che farebbe il demone: farli qui serve a mostrare il motivo
  /// accanto al campo invece di lasciare che la frase venga rifiutata in
  /// silenzio.
  void _applyWakePhrase(Strings strings, {required bool start}) {
    final controller = start ? _wakeStartController : _wakeStopController;
    final phrase = controller.text.trim();
    final other = start
        ? widget.client.wakePhraseStop
        : widget.client.wakePhraseStart;
    String? error;
    if (!isValidWakePhrase(phrase)) {
      error = strings.wakePhraseTooShort;
    } else if (normalizePhrase(phrase) == normalizePhrase(other)) {
      error = strings.wakePhrasesMustDiffer;
    }
    setState(() {
      if (start) {
        _wakeStartError = error;
      } else {
        _wakeStopError = error;
      }
    });
    if (error != null) return;
    if (start) {
      widget.client.setWakePhraseStart(phrase);
    } else {
      widget.client.setWakePhraseStop(phrase);
    }
  }

  /// Riquadro con l'ultima frase capita da uno dei due microfoni. Se e' vuoto
  /// lo si dice invece di lasciare uno spazio bianco, che sembrerebbe un
  /// difetto.
  Widget _heardBox(String label, String heard, Strings strings) {
    final vuoto = heard.trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              vuoto ? strings.wakeHeardNothingYet : heard,
              style: TextStyle(
                fontStyle: vuoto ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }

  ConnectionSettings _readForm() {
    return ConnectionSettings(
      host: _hostController.text.trim(),
      port:
          int.tryParse(_portController.text.trim()) ??
          SettingsService.defaultPort,
      token: _tokenController.text.trim(),
    );
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final result = await testConnection(_readForm());
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  /// Salva e applica le impostazioni di connessione non appena un campo
  /// perde il focus (tasto "fine" o tocco fuori), senza un pulsante
  /// "Salva" dedicato — stesso comportamento "attivo subito" degli altri
  /// interruttori di questa schermata. Incompleta (host/token mancanti) non
  /// fa nulla: l'utente sta ancora compilando, non ha senso avvisarlo ad
  /// ogni singolo campo lasciato a meta'.
  Future<void> _autoSaveConnection() async {
    final settings = _readForm();
    if (!settings.isComplete) return;
    final last = _lastAppliedSettings;
    if (last != null &&
        last.host == settings.host &&
        last.port == settings.port &&
        last.token == settings.token) {
      return;
    }
    _lastAppliedSettings = settings;
    await _settingsService.save(settings);
    if (!mounted) return;
    widget.client.connect(settings);
  }

  Future<void> _confirmRestartDaemon(Strings strings) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.restartDaemonConfirmTitle),
        content: Text(strings.restartDaemonConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(strings.restartDaemonButton),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    widget.client.restartDaemon();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(strings.restartDaemonSent)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings(widget.locale.language);
    final connected = widget.client.status == ConnectionStatus.connected;
    if (connected) {
      _syncVocabularyField();
      _syncWakePhraseFields();
    }

    return Scaffold(
      appBar: AppBar(title: Text(strings.connectionSettingsTitle)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (widget.client.certificateMismatch != null) ...[
                  Card(
                    color: Colors.orange.shade900,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            strings.certificateChangedTitle,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(color: Colors.white),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            strings.certificateChangedBody(
                              widget.client.certificateMismatch!,
                            ),
                            style: const TextStyle(color: Colors.white),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            icon: const Icon(Icons.gpp_maybe),
                            label: Text(strings.certificateAcceptButton),
                            onPressed: () =>
                                widget.client.trustNewCertificate(),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                Text(strings.connectionIntro),
                const SizedBox(height: 20),
                TextField(
                  controller: _hostController,
                  decoration: InputDecoration(
                    labelText: strings.hostLabel,
                    hintText: '192.168.1.50',
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  onSubmitted: (_) => _autoSaveConnection(),
                  onTapOutside: (_) => _autoSaveConnection(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _portController,
                  decoration: InputDecoration(
                    labelText: strings.portLabel,
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  onSubmitted: (_) => _autoSaveConnection(),
                  onTapOutside: (_) => _autoSaveConnection(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _tokenController,
                  obscureText: _obscureToken,
                  keyboardType: TextInputType.number,
                  maxLength: 5,
                  decoration: InputDecoration(
                    labelText: strings.tokenLabel,
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureToken
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                      onPressed: () =>
                          setState(() => _obscureToken = !_obscureToken),
                    ),
                  ),
                  onSubmitted: (_) => _autoSaveConnection(),
                  onTapOutside: (_) => _autoSaveConnection(),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering),
                  label: Text(
                    _testing
                        ? strings.testConnectionInProgress
                        : strings.testConnectionButton,
                  ),
                ),
                if (_testResult != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _testResult!,
                      style: TextStyle(
                        color: _testResult == strings.connectionSuccessful
                            ? Colors.green
                            : Colors.orange,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                const Divider(height: 40),

                Text(
                  strings.uiLanguage,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SegmentedButton<AppLanguage>(
                  segments: const [
                    ButtonSegment(
                      value: AppLanguage.it,
                      label: Text('Italiano'),
                    ),
                    ButtonSegment(
                      value: AppLanguage.en,
                      label: Text('English'),
                    ),
                  ],
                  selected: {widget.locale.language},
                  onSelectionChanged: (selection) =>
                      widget.locale.setLanguage(selection.first),
                ),

                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(strings.pushToTalkTitle),
                  subtitle: Text(strings.pushToTalkHelper),
                  value: _pushToTalk,
                  onChanged: (value) {
                    setState(() => _pushToTalk = value);
                    _settingsService.savePushToTalk(value);
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(strings.hapticsTitle),
                  subtitle: Text(strings.hapticsHelper),
                  value: _haptics,
                  onChanged: (value) {
                    setState(() => _haptics = value);
                    _settingsService.saveHapticFeedback(value);
                  },
                ),

                if (connected) ...[
                  const Divider(height: 40),
                  Text(
                    strings.dictationLanguage,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: dictationLanguages.containsKey(
                          widget.client.dictationLanguage,
                        )
                        ? widget.client.dictationLanguage
                        : 'it',
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final entry in dictationLanguages.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text('${entry.key} — ${entry.value}'),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        widget.client.setDictationLanguage(value);
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Ripristina clipboard'),
                    subtitle: Text(strings.restoreClipboardHelper),
                    value: widget.client.restoreClipboard,
                    onChanged: (value) =>
                        widget.client.setRestoreClipboard(value),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.pauseMediaWhileRecordingTitle),
                    subtitle: Text(strings.pauseMediaWhileRecordingHelper),
                    value: widget.client.pauseMediaWhileRecording,
                    onChanged: (value) =>
                        widget.client.setPauseMediaWhileRecording(value),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.translateToggleTitle),
                    subtitle: Text(strings.translateToggleHelper),
                    value: widget.client.translateEnabled,
                    onChanged: (value) =>
                        widget.client.setTranslateEnabled(value),
                  ),
                  if (widget.client.translateEnabled) ...[
                    const SizedBox(height: 12),
                    Text(
                      strings.translateTargetLabel,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: translateTargetLanguages.containsKey(
                            widget.client.translateTarget,
                          )
                          ? widget.client.translateTarget
                          : 'en',
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final entry in translateTargetLanguages.entries)
                          DropdownMenuItem(
                            value: entry.key,
                            child: Text('${entry.key} — ${entry.value}'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          widget.client.setTranslateTarget(value);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    if (widget.client.translateTarget == 'en') ...[
                      Text(
                        strings.translateEngineLabel,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      SegmentedButton<String>(
                        segments: [
                          ButtonSegment(
                            value: 'whisper',
                            label: Text(strings.translateEngineWhisper),
                          ),
                          ButtonSegment(
                            value: 'llm',
                            label: Text(strings.translateEngineLlm),
                          ),
                        ],
                        selected: {widget.client.translateEngine},
                        onSelectionChanged: (selection) =>
                            widget.client.setTranslateEngine(selection.first),
                      ),
                    ] else
                      Text(
                        strings.translateEngineNonEnglishNote,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],

                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.confirmBeforePasteTitle),
                    subtitle: Text(strings.confirmBeforePasteHelper),
                    value: widget.client.confirmBeforePaste,
                    onChanged: (value) =>
                        widget.client.setConfirmBeforePaste(value),
                  ),

                  const SizedBox(height: 8),

                  const Divider(height: 40),
                  Text(
                    strings.vocabularyTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _vocabularyController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      hintText: 'Stenografa, InvokeAI, Nobara',
                      helperText: strings.vocabularyHelper,
                      helperMaxLines: 4,
                    ),
                    onSubmitted: (value) =>
                        widget.client.setVocabulary(value.trim()),
                    onTapOutside: (_) =>
                        widget.client.setVocabulary(
                          _vocabularyController.text.trim(),
                        ),
                  ),

                  const Divider(height: 40),
                  Text(
                    strings.silenceTimeoutTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    initialValue: _silenceChoices.contains(
                          widget.client.silenceTimeout,
                        )
                        ? widget.client.silenceTimeout
                        : 10,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      helperText: strings.silenceTimeoutHelper,
                      helperMaxLines: 5,
                    ),
                    items: [
                      for (final seconds in _silenceChoices)
                        DropdownMenuItem(
                          value: seconds,
                          child: Text(
                            seconds == 0
                                ? strings.silenceTimeoutOff
                                : strings.silenceTimeoutSeconds(seconds),
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) widget.client.setSilenceTimeout(value);
                    },
                  ),

                  const Divider(height: 40),
                  Text(
                    strings.phoneMicTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.phoneMicSwitch),
                    subtitle: Text(strings.phoneMicHelper),
                    value: _phoneMicrophone,
                    onChanged: (value) {
                      setState(() => _phoneMicrophone = value);
                      // come per le altre preferenze locali, ad applicarla e'
                      // la schermata principale al ritorno (vedi
                      // _loadLocalPreferences in HomeScreen)
                      _settingsService.savePhoneMicrophone(value);
                    },
                  ),

                  const Divider(height: 40),
                  Text(
                    strings.wakeWordTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    strings.wakeWordIntro,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.wakeWordOnPc),
                    subtitle: Text(strings.wakeWordOnPcHelper),
                    value: widget.client.wakeWordEnabled,
                    onChanged: (value) =>
                        widget.client.setWakeWordEnabled(value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.wakeWordOnPhone),
                    subtitle: Text(strings.wakeWordOnPhoneHelper),
                    value: _phoneWakeWord,
                    onChanged: (value) {
                      setState(() => _phoneWakeWord = value);
                      // l'ascolto vero e proprio viene acceso dalla schermata
                      // principale al ritorno, come per le altre preferenze
                      // locali (vedi _loadLocalPreferences in HomeScreen)
                      _settingsService.savePhoneWakeWord(value);
                    },
                  ),
                  if (_phoneWakeWord)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(strings.wakeSilenceBeepsTitle),
                      subtitle: Text(strings.wakeSilenceBeepsHelper),
                      value: _silenceBeeps,
                      onChanged: (value) {
                        setState(() => _silenceBeeps = value);
                        _settingsService.saveSilenceBeeps(value);
                        widget.wakeWord?.silenceBeeps = value;
                      },
                    ),
                  if (widget.client.wakeWordEnabled || _phoneWakeWord) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _wakeStartController,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        labelText: strings.wakePhraseStartLabel,
                        errorText: _wakeStartError,
                        helperText: strings.wakePhraseHelper,
                        helperMaxLines: 4,
                      ),
                      onSubmitted: (_) => _applyWakePhrase(strings, start: true),
                      onTapOutside: (_) =>
                          _applyWakePhrase(strings, start: true),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _wakeStopController,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        labelText: strings.wakePhraseStopLabel,
                        errorText: _wakeStopError,
                      ),
                      onSubmitted: (_) =>
                          _applyWakePhrase(strings, start: false),
                      onTapOutside: (_) =>
                          _applyWakePhrase(strings, start: false),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      strings.wakeHeardTitle,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      strings.wakeHeardHelper,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    if (widget.client.wakeWordEnabled)
                      _heardBox(
                        strings.wakeHeardFromPc,
                        widget.client.wakeHeardOnPc,
                        strings,
                      ),
                    if (_phoneWakeWord)
                      _heardBox(
                        strings.wakeHeardFromPhone,
                        widget.wakeWord?.lastHeard ?? '',
                        strings,
                      ),
                  ],

                  const Divider(height: 40),
                  Text(
                    strings.securityTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      widget.client.connectionSecure
                          ? Icons.lock
                          : Icons.lock_open,
                      color: widget.client.connectionSecure
                          ? Colors.green.shade600
                          : Colors.orange.shade700,
                    ),
                    title: Text(
                      widget.client.connectionSecure
                          ? strings.connectionEncrypted
                          : strings.connectionPlain,
                    ),
                    subtitle: Text(
                      widget.client.connectionSecure
                          ? strings.certificateFingerprint(
                              widget.client.peerFingerprint ?? '—',
                            )
                          // se il PC ha un certificato ma il canale e'
                          // rimasto in chiaro, mostrare la sua impronta
                          // aiuta a capire cosa si sarebbe dovuto usare
                          : widget.client.tlsAvailable
                              ? '${strings.connectionPlainHelper}\n'
                                  '${strings.certificateFingerprint(widget.client.daemonFingerprint ?? '—')}'
                              : strings.connectionPlainHelper,
                    ),
                  ),
                  if (widget.client.tlsAvailable)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(strings.requireTlsTitle),
                      subtitle: Text(strings.requireTlsHelper),
                      value: widget.client.requireTls,
                      onChanged: (value) => widget.client.setRequireTls(value),
                    ),

                  const Divider(height: 40),
                  OutlinedButton.icon(
                    onPressed: () => _confirmRestartDaemon(strings),
                    icon: const Icon(Icons.restart_alt),
                    label: Text(strings.restartDaemonButton),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
