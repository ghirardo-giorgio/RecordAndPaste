import 'package:flutter/services.dart';

/// Silenzia i segnali acustici di sistema mentre l'app aspetta la frase di
/// attivazione (vedi WakeWordService).
///
/// Android li fa suonare a ogni sessione di ascolto — non a ogni dettatura — e
/// le sessioni vengono chiuse e riaperte dal sistema anche quando nessuno
/// parla: senza silenziarli il telefono trilla in continuazione a vuoto. Il
/// lavoro vero lo fa MainActivity.kt; qui c'e' solo il collegamento.
///
/// Su iOS non serve (il riconoscitore non emette suoni) e i metodi non fanno
/// nulla.
class SystemSounds {
  static const _channel = MethodChannel('record_and_paste/system_sounds');

  /// Quante volte e' stato chiesto il silenzio senza ancora ripristinarlo:
  /// evita che un ripristino di troppo riaccenda i suoni mentre l'ascolto sta
  /// ancora andando.
  static int _depth = 0;

  static bool get muted => _depth > 0;

  static Future<void> mute() async {
    _depth++;
    if (_depth > 1) return;
    try {
      await _channel.invokeMethod<void>('mute');
    } on PlatformException {
      // niente canale (iOS, o build senza la parte nativa): si continua senza
      _depth = 0;
    } on MissingPluginException {
      _depth = 0;
    }
  }

  static Future<void> unmute() async {
    if (_depth == 0) return;
    _depth--;
    if (_depth > 0) return;
    try {
      await _channel.invokeMethod<void>('unmute');
    } on PlatformException {
      // se non si riesce a ripristinare non si puo' fare molto, ma il telefono
      // non va lasciato muto in silenzio: MainActivity ripristina comunque
      // quando l'app viene chiusa
    } on MissingPluginException {
      // idem
    }
  }
}
