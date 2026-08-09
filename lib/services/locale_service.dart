import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';

/// Lingua dell'interfaccia (separata dalla lingua di dettatura, che e'
/// configurazione del demone/Whisper): preferenza puramente locale al
/// telefono, persistita via SharedPreferences.
class LocaleService extends ChangeNotifier {
  static const _key = 'ui_language';

  AppLanguage _language = AppLanguage.it;
  AppLanguage get language => _language;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_key);
    _language = code == 'en' ? AppLanguage.en : AppLanguage.it;
    notifyListeners();
  }

  Future<void> setLanguage(AppLanguage language) async {
    if (language == _language) return;
    _language = language;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, language == AppLanguage.en ? 'en' : 'it');
  }
}
