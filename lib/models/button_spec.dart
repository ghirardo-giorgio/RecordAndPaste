import 'package:flutter/material.dart';

/// Nomi di icona riconosciuti per i pulsanti, scelti dall'LLM (via MCP) o
/// dall'utente (long-press su un pulsante in modalita' modifica). Deve
/// restare sincronizzata con ICON_NAMES in daemon.py: un nome diverso da
/// questi non e' valido e viene rifiutato dal demone prima ancora di
/// arrivare qui.
const Map<String, IconData> iconByName = {
  'keyboard': Icons.keyboard,
  'delete': Icons.delete,
  'delete_sweep': Icons.delete_sweep,
  'cancel': Icons.cancel,
  'close': Icons.close,
  'warning': Icons.warning_amber_rounded,
  'refresh': Icons.refresh,
  'autorenew': Icons.autorenew,
  'stop': Icons.stop,
  'play_arrow': Icons.play_arrow,
  'pause': Icons.pause,
  'check': Icons.check,
  'check_circle': Icons.check_circle,
  'content_copy': Icons.content_copy,
  'content_paste': Icons.content_paste,
  'content_cut': Icons.content_cut,
  'save': Icons.save,
  'folder': Icons.folder,
  'image': Icons.image,
  'photo': Icons.photo,
  'brush': Icons.brush,
  'palette': Icons.palette,
  'undo': Icons.undo,
  'redo': Icons.redo,
  'send': Icons.send,
  'download': Icons.download,
  'upload': Icons.upload,
  'settings': Icons.settings,
  'search': Icons.search,
  'star': Icons.star,
  'favorite': Icons.favorite,
  'lock': Icons.lock,
  'lock_open': Icons.lock_open,
  'visibility': Icons.visibility,
  'edit': Icons.edit,
  'add': Icons.add,
  'remove': Icons.remove,
  'arrow_upward': Icons.arrow_upward,
  'arrow_downward': Icons.arrow_downward,
  'arrow_back': Icons.arrow_back,
  'arrow_forward': Icons.arrow_forward,
  'mic': Icons.mic,
  'volume_up': Icons.volume_up,
  'volume_off': Icons.volume_off,
  'power_settings_new': Icons.power_settings_new,
  'sync': Icons.sync,
  'cloud': Icons.cloud,
  'home': Icons.home,
  'menu': Icons.menu,
  'more_horiz': Icons.more_horiz,
  'info': Icons.info,
  'help': Icons.help,
  'layers': Icons.layers,
  'terminal': Icons.terminal,
  'code': Icons.code,
  'bolt': Icons.bolt,
  'flash_on': Icons.flash_on,
  'clear_all': Icons.clear_all,
  'restart_alt': Icons.restart_alt,
  // strumenti di disegno/fotoritocco (es. dashboard per Gimp/InvokeAI)
  'crop_free': Icons.crop_free,
  'gesture': Icons.gesture,
  'colorize': Icons.colorize,
  'healing': Icons.healing,
  'gradient': Icons.gradient,
  'zoom_in': Icons.zoom_in,
  'rotate_right': Icons.rotate_right,
  'rotate_left': Icons.rotate_left,
  'straighten': Icons.straighten,
  'format_paint': Icons.format_paint,
  'highlight': Icons.highlight,
  'touch_app': Icons.touch_app,
  'near_me': Icons.near_me,
  'pan_tool': Icons.pan_tool,
  'opacity': Icons.opacity,
  'tune': Icons.tune,
  'filter_alt': Icons.filter_alt,
  'crop': Icons.crop,
  'grain': Icons.grain,
  'auto_fix_high': Icons.auto_fix_high,
  'line_weight': Icons.line_weight,
  'flip': Icons.flip,
  'exposure': Icons.exposure,
  'contrast': Icons.contrast,
  // avvio applicazioni (kind="launch"), snippet di testo (kind="text") e
  // sequenze di scorciatoie (kind="macro")
  'rocket_launch': Icons.rocket_launch,
  'open_in_new': Icons.open_in_new,
  'apps': Icons.apps,
  'desktop_windows': Icons.desktop_windows,
  'text_snippet': Icons.text_snippet,
  'notes': Icons.notes,
  'short_text': Icons.short_text,
  'playlist_play': Icons.playlist_play,
  'history': Icons.history,
};

const IconData defaultButtonIcon = Icons.keyboard;

/// Tinta di un pulsante: le otto della gamma, con il nome che si vede nel
/// selettore (l'aspetto non e' l'unico modo per riconoscerle).
class ButtonPaletteColor {
  const ButtonPaletteColor(this.name, this.hex);

  final String name;
  final String hex;

  Color get color => colorFromHex(hex)!;
}

/// Gamma dei pulsanti: tinte desaturate che restano leggibili con
/// l'etichetta bianca sopra e non litigano fra loro quando la griglia e'
/// piena. Corallo e' l'accento (azioni che spiccano), Ardesia il neutro dei
/// pulsanti senza colore proprio.
const buttonPalette = <ButtonPaletteColor>[
  ButtonPaletteColor('Corallo', '#e1543f'),
  ButtonPaletteColor('Ambra', '#c8891e'),
  ButtonPaletteColor('Oliva', '#7c8c3c'),
  ButtonPaletteColor('Smeraldo', '#2f9e6e'),
  ButtonPaletteColor('Ceruleo', '#2681a8'),
  ButtonPaletteColor('Indaco', '#5b5fc7'),
  ButtonPaletteColor('Magenta', '#a84ba5'),
  ButtonPaletteColor('Ardesia', '#5d6a75'),
];

/// Ardesia: il neutro della gamma, per i pulsanti a cui non e' stato dato un
/// colore.
const Color defaultButtonColor = Color(0xFF5D6A75);

IconData iconForName(String? name) {
  if (name == null) return defaultButtonIcon;
  return iconByName[name] ?? defaultButtonIcon;
}

/// Converte una stringa "#RRGGBB" in un [Color]; `null` se assente o non
/// valida (in tal caso il chiamante usa [defaultButtonColor]).
Color? colorFromHex(String? hex) {
  if (hex == null || hex.length != 7 || !hex.startsWith('#')) return null;
  final value = int.tryParse(hex.substring(1), radix: 16);
  if (value == null) return null;
  return Color(0xFF000000 | value);
}

/// Converte un [Color] nel formato "#RRGGBB" usato dal protocollo.
String colorToHex(Color color) {
  final value = color.toARGB32() & 0x00FFFFFF;
  return '#${value.toRadixString(16).padLeft(6, '0')}';
}

/// Nero o bianco, a seconda di quale garantisce piu' contrasto sopra
/// [background] (in base alla luminanza percepita): evita etichette/icone
/// illeggibili sui colori chiari scelti per i pulsanti (es. giallo).
Color contrastingOn(Color background) {
  return background.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;
}

/// Tipi di pulsante il cui aspetto segue lo stato della registrazione
/// (invece del colore/icona scelti dall'utente): tutti avviano e fermano la
/// stessa registrazione globale, cambia solo cosa viene fatto del testo
/// dettato. Vedi MIC_KINDS in daemon.py.
const micKinds = {'record', 'ai_command'};

/// Un pulsante posizionato in una cella della griglia (row, col), entrambi
/// a partire da 0. `kind` e':
/// - `"record"`: avvia/ferma la registrazione e incolla il testo dettato;
/// - `"ai_command"`: come "record" ma il testo dettato viene interpretato da
///   un LLM locale ed eseguito come combinazione di tasti (o avvio di
///   un'applicazione);
/// - `"keys"`: simula la combinazione di tasti `combo` (es. "ctrl+c");
/// - `"macro"`: esegue in sequenza le combinazioni di `combos`, con una
///   pausa di `delayMs` fra l'una e l'altra;
/// - `"text"`: incolla sul PC il testo fisso `text`;
/// - `"launch"`: avvia sul PC l'applicazione `appId` (nome in `appName`);
/// - `"paste_last"`: re-incolla l'ultima dettatura, senza registrarne una
///   nuova (per quando il cursore non era dove doveva).
///
/// `color` e `icon` sono opzionali: se assenti il pulsante usa l'aspetto
/// neutro di default (non applicabile ai tipi in [micKinds], il cui aspetto
/// segue lo stato).
class ButtonSpec {
  const ButtonSpec({
    required this.id,
    required this.label,
    required this.kind,
    required this.row,
    required this.col,
    this.combo,
    this.color,
    this.icon,
    this.combos = const [],
    this.delayMs,
    this.text,
    this.appId,
    this.appName,
  });

  final String id;
  final String label;
  final String kind;
  final int row;
  final int col;
  final String? combo;
  final String? color;
  final String? icon;
  final List<String> combos;
  final int? delayMs;
  final String? text;
  final String? appId;
  final String? appName;

  bool get isRecord => kind == 'record';
  bool get isAiCommand => kind == 'ai_command';
  bool get isMic => micKinds.contains(kind);
  bool get isKeys => kind == 'keys';
  bool get isMacro => kind == 'macro';
  bool get isText => kind == 'text';
  bool get isLaunch => kind == 'launch';
  bool get isPasteLast => kind == 'paste_last';

  Color get displayColor => colorFromHex(color) ?? defaultButtonColor;

  /// Icona da mostrare: quella scelta, oppure — se non ne e' stata scelta
  /// nessuna — una coerente col tipo di pulsante, cosi' una macro o un
  /// avvio applicazione non sembrano una scorciatoia qualsiasi.
  IconData get displayIcon {
    if (icon != null) return iconForName(icon);
    switch (kind) {
      case 'macro':
        return Icons.playlist_play;
      case 'text':
        return Icons.text_snippet;
      case 'launch':
        return Icons.rocket_launch;
      case 'paste_last':
        return Icons.content_paste;
      default:
        return defaultButtonIcon;
    }
  }

  /// Riga descrittiva mostrata sotto l'etichetta nei dialoghi (rimozione,
  /// elenco): cosa fa davvero questo pulsante.
  String get actionSummary {
    switch (kind) {
      case 'keys':
        return combo ?? '';
      case 'macro':
        return combos.join(' → ');
      case 'text':
        final t = text ?? '';
        return t.length <= 60 ? t : '${t.substring(0, 60)}…';
      case 'launch':
        return appName ?? appId ?? '';
      default:
        return '';
    }
  }

  factory ButtonSpec.fromJson(Map<String, dynamic> json) {
    return ButtonSpec(
      id: json['id'] as String,
      label: json['label'] as String,
      kind: json['kind'] as String,
      row: json['row'] as int,
      col: json['col'] as int,
      combo: json['combo'] as String?,
      color: json['color'] as String?,
      icon: json['icon'] as String?,
      combos:
          (json['combos'] as List<dynamic>? ?? const [])
              .map((c) => c as String)
              .toList(),
      delayMs: json['delay_ms'] as int?,
      text: json['text'] as String?,
      appId: json['app_id'] as String?,
      appName: json['app_name'] as String?,
    );
  }
}

/// Un'applicazione installata sul PC, come la elenca il demone: `id` opaco
/// (un percorso .desktop su Linux, un AppID su Windows...) da non costruire
/// mai a mano, piu' un nome leggibile.
class LaunchableApp {
  const LaunchableApp({required this.id, required this.name});

  final String id;
  final String name;

  factory LaunchableApp.fromJson(Map<String, dynamic> json) => LaunchableApp(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
      );
}

/// Una dettatura passata, come la espone il demone: solo l'anteprima viaggia
/// in rete, il testo integrale resta sul PC e il re-incolla avviene per [id]
/// (vedi _paste_history_entry in daemon.py).
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.preview,
    required this.pasted,
    required this.at,
  });

  final String id;
  final String preview;

  /// Se l'incolla automatico era riuscito: quelle fallite sono proprio le
  /// dettature che ha senso ripescare da qui.
  final bool pasted;
  final DateTime at;

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        id: json['id'] as String,
        preview: json['preview'] as String? ?? '',
        pasted: json['pasted'] as bool? ?? false,
        at: DateTime.fromMillisecondsSinceEpoch(
          ((json['at'] as num? ?? 0) * 1000).round(),
        ),
      );
}

/// Un riproduttore multimediale attivo sul PC (browser, player video...),
/// come lo riporta il demone via MPRIS. Il telefono ne mostra un pulsante
/// play/pausa per fermare un video prima di dettare senza tornare alla
/// tastiera. `id` e' opaco (il bus name D-Bus) e va rimandato invariato.
class MediaPlayerInfo {
  const MediaPlayerInfo({
    required this.id,
    required this.name,
    required this.title,
    required this.playing,
  });

  final String id;

  /// Applicazione che riproduce (es. "Brave").
  final String name;

  /// Titolo di quello che sta riproducendo, se lo dichiara.
  final String title;
  final bool playing;

  /// Riga mostrata nel tooltip del pulsante: il titolo quando c'e', il nome
  /// dell'applicazione quando il player non lo dichiara.
  String get label => title.isNotEmpty ? title : name;

  factory MediaPlayerInfo.fromJson(Map<String, dynamic> json) =>
      MediaPlayerInfo(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        title: json['title'] as String? ?? '',
        playing: json['playing'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is MediaPlayerInfo &&
      other.id == id &&
      other.name == name &&
      other.title == title &&
      other.playing == playing;

  @override
  int get hashCode => Object.hash(id, name, title, playing);
}

/// Una dashboard: nome e griglia rows x cols di pulsanti. L'app telefono ne
/// puo' avere piu' d'una, raggiungibili con uno swipe orizzontale.
class Dashboard {
  const Dashboard({
    required this.id,
    required this.name,
    required this.rows,
    required this.cols,
    required this.buttons,
    this.match = '',
    this.vocabulary = '',
    this.appId,
  });

  final String id;
  final String name;
  final int rows;
  final int cols;
  final List<ButtonSpec> buttons;

  /// Testo (case-insensitive) da cercare nel nome applicazione/titolo della
  /// finestra col focus sul PC per suggerire automaticamente questa
  /// dashboard. Stringa vuota = nessuna associazione.
  final String match;

  /// Termini che Whisper deve trascrivere correttamente quando la dettatura
  /// parte da un pulsante di questa dashboard (gergo dell'app a cui e'
  /// dedicata). Stringa vuota = nessun vocabolario specifico.
  final String vocabulary;

  /// Applicazione del PC a cui questa dashboard si riferisce, risolta dal
  /// demone (pulsante "avvia applicazione" o campo "match"). Serve a
  /// chiederne l'icona e disegnarla in filigrana dietro i pulsanti.
  final String? appId;

  factory Dashboard.fromJson(Map<String, dynamic> json) {
    final rawButtons = json['buttons'] as List<dynamic>? ?? const [];
    return Dashboard(
      id: json['id'] as String,
      name: json['name'] as String,
      rows: json['rows'] as int,
      cols: json['cols'] as int,
      match: json['match'] as String? ?? '',
      vocabulary: json['vocabulary'] as String? ?? '',
      appId: json['app_id'] as String?,
      buttons: rawButtons
          .map((b) => ButtonSpec.fromJson(b as Map<String, dynamic>))
          .toList(),
    );
  }

  ButtonSpec? at(int row, int col) {
    for (final b in buttons) {
      if (b.row == row && b.col == col) return b;
    }
    return null;
  }
}

/// Una delle interpretazioni proposte dal demone quando un comando vocale IA
/// risulta ambiguo (vedi `choose_shortcut` nel protocollo). Non fa parte del
/// layout salvato: vive solo per la durata della scelta. L'opzione e' una
/// combinazione di tasti ([combo]), una macro multi-passo ([combos]) o
/// l'avvio di un'applicazione ([appId]).
class ShortcutChoice {
  const ShortcutChoice({
    required this.label,
    this.combo = '',
    this.combos = const [],
    this.appId,
    this.appName,
  });

  final String label;
  final String combo;
  final List<String> combos;
  final String? appId;
  final String? appName;

  bool get isApp => appId != null && appId!.isNotEmpty;
  bool get isMacro => combos.isNotEmpty;

  /// Riga sotto l'etichetta nel pannello di scelta: la combinazione, i
  /// passi della macro, oppure il nome dell'app da avviare.
  String get detail {
    if (isApp) return appName ?? '';
    if (isMacro) return combos.join(' → ');
    return combo;
  }

  factory ShortcutChoice.fromJson(Map<String, dynamic> json) => ShortcutChoice(
        label: json['label'] as String? ?? '',
        combo: json['combo'] as String? ?? '',
        combos: (json['combos'] as List<dynamic>? ?? const [])
            .map((c) => c as String)
            .toList(),
        appId: json['app_id'] as String?,
        appName: json['app_name'] as String?,
      );
}
