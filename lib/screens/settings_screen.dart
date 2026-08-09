import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/connection_settings.dart';
import '../models/daemon_state.dart';
import '../services/locale_service.dart';
import '../services/settings_service.dart';
import '../services/steno_client.dart';

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

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.client, required this.locale});

  final StenoClient client;
  final LocaleService locale;

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

  bool _obscureToken = true;
  bool _testing = false;
  String? _testResult;
  bool _loaded = false;
  bool _pushToTalk = false;
  bool _haptics = true;
  /// versione della configurazione gia' riportata nel campo vocabolario:
  /// evita di sovrascrivere quello che l'utente sta scrivendo ad ogni
  /// aggiornamento inviato dal demone
  int _vocabularyConfigVersion = -1;
  /// ultime impostazioni di connessione gia' salvate/applicate: evita di
  /// riconnettersi inutilmente (con relativo sfarfallio dello stato) quando
  /// l'utente tocca fuori da un campo senza averlo davvero modificato
  ConnectionSettings? _lastAppliedSettings;

  @override
  void initState() {
    super.initState();
    widget.locale.addListener(_onChanged);
    widget.client.addListener(_onChanged);
    _load();
  }

  @override
  void dispose() {
    widget.locale.removeListener(_onChanged);
    widget.client.removeListener(_onChanged);
    _hostController.dispose();
    _portController.dispose();
    _tokenController.dispose();
    _vocabularyController.dispose();
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
    if (mounted) {
      setState(() {
        _pushToTalk = pushToTalk;
        _haptics = haptics;
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
    if (connected) _syncVocabularyField();

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
                    hintText: '192.168.50.133',
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
