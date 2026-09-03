/// Riconoscimento della frase di attivazione, senza dipendenze dal
/// riconoscitore vocale: e' la stessa logica di `_normalize_phrase` e
/// `_phrase_in_text` in daemon.py, replicata qui perche' sul telefono
/// l'ascolto avviene in locale (vedi WakeWordService).
///
/// Le due implementazioni devono restare allineate: se cambia il modo di
/// confrontare le frasi, la stessa parola pronunciata darebbe risultati
/// diversi a seconda di quale microfono l'ha sentita.
library;

/// Quanto puo' discostarsi il parlato riconosciuto dalla frase attesa, in
/// frazione dei suoi caratteri: si contano le lettere da correggere (distanza
/// di edit), non una percentuale di somiglianza. Stesso valore di
/// WAKE_MATCH_EDIT_FRACTION in daemon.py.
///
/// Il criterio precedente (rapporto di somiglianza) non funzionava sulle
/// parole corte: "jarvis" contro "giarvis" vale 0.77, quindi per tollerare gli
/// errori veri bisognava tenere la soglia cosi' bassa da far scattare
/// l'attivazione su parole diverse. Contare le modifiche separa i due casi —
/// "giarvis" dista 2 lettere, "arrivi" ne dista 4.
const double wakeMatchEditFraction = 0.25;

/// Lunghezza minima della frase (dopo la normalizzazione): sotto, verrebbe
/// riconosciuta dentro le parole di una conversazione normale.
const int wakePhraseMinChars = 3;

/// La frase puo' contenere piu' varianti separate da virgola (vedi
/// [phraseVariants]), quindi il limite e' sulla riga intera.
const int wakePhraseMaxChars = 160;

const Map<String, String> _accents = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
  'ñ': 'n', 'ç': 'c', 'ý': 'y',
};

/// Minuscole, senza accenti ne' punteggiatura, spazi singoli.
String normalizePhrase(String? text) {
  if (text == null) return '';
  final buffer = StringBuffer();
  for (final char in text.toLowerCase().split('')) {
    final plain = _accents[char] ?? char;
    // si tiene solo cio' che il riconoscitore puo' produrre in modo stabile:
    // la punteggiatura varia da una trascrizione all'altra
    buffer.write(RegExp(r'[a-z0-9]').hasMatch(plain) ? plain : ' ');
  }
  return buffer.toString().trim().split(RegExp(r'\s+')).join(' ');
}

/// Quante lettere bisogna cambiare, togliere o aggiungere per passare da [a]
/// a [b]. Calcolata riga per riga, senza allocare l'intera matrice.
int editDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var previous = List<int>.generate(b.length + 1, (i) => i);
  var current = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    current[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final substitution =
          previous[j - 1] + (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1);
      final deletion = previous[j] + 1;
      final insertion = current[j - 1] + 1;
      var best = substitution < deletion ? substitution : deletion;
      if (insertion < best) best = insertion;
      current[j] = best;
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[b.length];
}

/// Quanti errori si accettano su una frase lunga [length]. Almeno uno,
/// altrimenti le frasi corte non tollererebbero nulla.
int maxEdits(int length) {
  final allowed = (length * wakeMatchEditFraction).round();
  return allowed < 1 ? 1 : allowed;
}

/// Le forme accettate per una frase, separate da virgola — gemella di
/// `_phrase_variants` in daemon.py.
///
/// Il riconoscitore scrive quello che sente nella lingua di dettatura:
/// "Jarvis" detto in italiano diventa "già visto" o "ciarvis". Sul PC si
/// corregge il tiro suggerendo la grafia al modello, ma il riconoscitore di
/// sistema del telefono non accetta suggerimenti: qui l'unico rimedio e' che
/// l'utente elenchi come suona davvero la sua frase.
List<String> phraseVariants(String? phrase) {
  if (phrase == null) return const [];
  final variants = <String>[];
  for (final piece in phrase.split(',')) {
    final normalized = normalizePhrase(piece);
    if (normalized.isNotEmpty && !variants.contains(normalized)) {
      variants.add(normalized);
    }
  }
  return variants;
}

/// True se [phrase] (o una delle sue varianti) compare in [text], tollerando
/// gli errori di trascrizione. Confronta la frase con ogni sequenza di parole
/// lunga quanto lei, piu' una parola in meno e una in piu': il riconoscitore a
/// volte fonde o spezza le parole.
///
/// [onlyTail] limita la ricerca alle ultime parole del testo. Serve durante la
/// dettatura: il telefono sente anche quello che si sta dettando, e cercare la
/// frase di stop in tutto il discorso la troverebbe in mezzo a una frase
/// qualsiasi, interrompendo la dettatura a meta'.
bool phraseInText(String phrase, String text, {bool onlyTail = false}) {
  final haystack = normalizePhrase(text);
  if (haystack.isEmpty) return false;
  final allWords = haystack.split(' ');
  for (final target in phraseVariants(phrase)) {
    final span = target.split(' ').length;
    // con onlyTail si guardano solo le ultime parole: quante bastano per
    // contenere la frase, piu' un margine per una parola spezzata
    final words = onlyTail && allWords.length > span + 2
        ? allWords.sublist(allWords.length - (span + 2))
        : allWords;
    if (words.join(' ').contains(target)) return true;
    final allowed = maxEdits(target.length);
    final sizes = <int>{span > 1 ? span - 1 : 1, span, span + 1};
    for (final size in sizes) {
      for (var start = 0; start + size <= words.length; start++) {
        final window = words.sublist(start, start + size).join(' ');
        // una finestra molto piu' lunga o corta non puo' rientrare nel
        // margine: si evita di calcolare la distanza per niente
        if ((window.length - target.length).abs() > allowed) continue;
        if (editDistance(target, window) <= allowed) return true;
      }
    }
  }
  return false;
}

/// Se la frase e' accettabile come frase di attivazione. Stessi criteri della
/// validazione lato demone, applicati qui per segnalare l'errore mentre
/// l'utente scrive invece che dopo il rifiuto del demone.
bool isValidWakePhrase(String? phrase) {
  if (phrase == null) return false;
  if (phrase.trim().length > wakePhraseMaxChars) return false;
  final variants = phraseVariants(phrase);
  if (variants.isEmpty) return false;
  // una variante troppo corta farebbe scattare l'attivazione dentro le parole
  // di una conversazione qualsiasi
  return variants.every((v) => v.length >= wakePhraseMinChars);
}
