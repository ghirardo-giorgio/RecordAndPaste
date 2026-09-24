import 'package:shared_preferences/shared_preferences.dart';

import '../models/connection_settings.dart';

/// Legge e salva l'indirizzo del PC, la porta e il token di autenticazione
/// usati per collegarsi al demone Stenografa.
class SettingsService {
  static const defaultPort = 8765;

  static const _keyHost = 'steno_host';
  static const _keyPort = 'steno_port';
  static const _keyToken = 'steno_token';
  static const _keyFollowActiveApp = 'follow_active_app';
  static const _keyPushToTalk = 'push_to_talk';
  static const _keyHaptics = 'haptic_feedback';
  static const _keyPinnedCert = 'pinned_cert_fingerprint';
  static const _keyPhoneWakeWord = 'phone_wake_word';
  static const _keyPhoneMicrophone = 'phone_microphone';
  static const _keySilenceBeeps = 'wake_silence_beeps';

  Future<ConnectionSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return ConnectionSettings(
      host: prefs.getString(_keyHost) ?? '',
      port: prefs.getInt(_keyPort) ?? defaultPort,
      token: prefs.getString(_keyToken) ?? '',
    );
  }

  Future<void> save(ConnectionSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyHost, settings.host);
    await prefs.setInt(_keyPort, settings.port);
    await prefs.setString(_keyToken, settings.token);
  }

  /// Impronta del certificato TLS del PC accettata al primo collegamento
  /// ("trust on first use"): dai collegamenti successivi un certificato
  /// diverso viene rifiutato, cosi' nessun altro dispositivo sulla stessa
  /// rete puo' spacciarsi per il PC. `null` finche' non ci si e' mai
  /// collegati in TLS.
  Future<String?> loadPinnedCertificate() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyPinnedCert);
  }

  Future<void> savePinnedCertificate(String? fingerprint) async {
    final prefs = await SharedPreferences.getInstance();
    if (fingerprint == null) {
      await prefs.remove(_keyPinnedCert);
    } else {
      await prefs.setString(_keyPinnedCert, fingerprint);
    }
  }

  /// Se i pulsanti microfono registrano mentre li tieni premuti invece di
  /// funzionare da interruttore (tocca per iniziare, tocca per fermare).
  /// Disattivo di default: l'interruttore e' piu' comodo per le dettature
  /// lunghe, il push-to-talk per le frasi brevi.
  Future<bool> loadPushToTalk() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyPushToTalk) ?? false;
  }

  Future<void> savePushToTalk(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyPushToTalk, value);
  }

  /// Vibrazione a inizio/fine registrazione e sull'esito: il riscontro
  /// testuale del demone arriva come notifica sul PC, cioe' proprio dove
  /// l'utente non sta guardando mentre usa il telefono. Attiva di default.
  Future<bool> loadHapticFeedback() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyHaptics) ?? true;
  }

  Future<void> saveHapticFeedback(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyHaptics, value);
  }

  /// Se il telefono ascolta le frasi di attivazione con il proprio microfono
  /// (vedi WakeWordService). E' una preferenza del singolo telefono, distinta
  /// dall'ascolto sul PC (`wake_word_enabled` nella config del demone): le
  /// frasi da riconoscere invece sono le stesse, e arrivano dal demone.
  /// Disattivo di default, come l'ascolto sul PC.
  Future<bool> loadPhoneWakeWord() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyPhoneWakeWord) ?? false;
  }

  Future<void> savePhoneWakeWord(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyPhoneWakeWord, value);
  }

  /// Se a registrare la dettatura e' il microfono del telefono invece di
  /// quello del PC. A trascrivere resta il PC, che riceve l'audio mentre lo si
  /// detta (vedi PhoneMicrophone): serve quando il microfono del PC non e'
  /// utilizzabile perche' occupato da un'altra applicazione.
  ///
  /// E' una preferenza del singolo telefono, come [loadPhoneWakeWord].
  /// Disattiva di default: finche' il microfono del PC funziona, e' quello
  /// piu' comodo — non consuma la batteria del telefono e non dipende dalla
  /// rete.
  Future<bool> loadPhoneMicrophone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyPhoneMicrophone) ?? false;
  }

  Future<void> savePhoneMicrophone(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyPhoneMicrophone, value);
  }

  /// Se silenziare i segnali acustici del riconoscimento vocale mentre si
  /// aspetta la frase di attivazione. Attivo di default: Android li fa suonare
  /// a ogni sessione di ascolto, non a ogni dettatura, e senza silenziarli il
  /// telefono trilla di continuo anche stando zitti. Si puo' spegnere perche'
  /// il silenzio copre anche l'audio multimediale del telefono.
  Future<bool> loadSilenceBeeps() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keySilenceBeeps) ?? true;
  }

  Future<void> saveSilenceBeeps(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySilenceBeeps, value);
  }

  /// Preferenza locale (non sincronizzata col demone): se attiva, l'app
  /// passa da sola alla dashboard associata all'applicazione col focus sul
  /// PC. Disattivata di default per non interferire con la navigazione
  /// manuale finche' l'utente non la sceglie esplicitamente.
  Future<bool> loadFollowActiveApp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyFollowActiveApp) ?? false;
  }

  Future<void> saveFollowActiveApp(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyFollowActiveApp, value);
  }
}
