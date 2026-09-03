// Riconoscimento della frase di attivazione sul telefono. Gli stessi casi
// sono provati lato demone in stenografa/tests/test_wake_word.py: le due
// implementazioni devono comportarsi allo stesso modo, altrimenti la stessa
// parola darebbe esiti diversi a seconda di quale microfono l'ha sentita.
import 'package:flutter_test/flutter_test.dart';

import 'package:record_and_paste/services/wake_phrase.dart';

void main() {
  group('normalizePhrase', () {
    test('ignora maiuscole, accenti e punteggiatura', () {
      expect(normalizePhrase('Jarvis, stop!'), 'jarvis stop');
      expect(normalizePhrase('Perché  no'), 'perche no');
      expect(normalizePhrase('   '), '');
      expect(normalizePhrase(null), '');
    });
  });

  group('phraseInText', () {
    test('riconosce la frase esatta e dentro un discorso piu' ' lungo', () {
      expect(phraseInText('jarvis', 'Jarvis'), isTrue);
      expect(phraseInText('jarvis', 'Ok Jarvis, dimmi tutto'), isTrue);
      expect(phraseInText('jarvis stop', 'va bene, Jarvis stop.'), isTrue);
    });

    test('tollera gli errori tipici del riconoscitore', () {
      for (final heard in ['Giarvis', 'Jervis', 'Jarvix', 'giarvis ']) {
        expect(phraseInText('jarvis', heard), isTrue, reason: heard);
      }
    });

    test('non scatta su parlato che non la contiene', () {
      expect(phraseInText('jarvis', ''), isFalse);
      expect(phraseInText('jarvis', 'domani vado al mare'), isFalse);
      expect(phraseInText('computer accendi', 'accendi la luce'), isFalse);
    });

    test('la frase di stop non viene sentita nella frase di avvio', () {
      // altrimenti la dettatura si fermerebbe appena avviata
      expect(phraseInText('jarvis stop', 'Jarvis'), isFalse);
    });

    test('una frase vuota non corrisponde mai', () {
      expect(phraseInText('', 'qualsiasi cosa'), isFalse);
    });
  });

  group('isValidWakePhrase', () {
    test('accetta frasi ragionevoli', () {
      expect(isValidWakePhrase('jarvis'), isTrue);
      expect(isValidWakePhrase('ok computer'), isTrue);
    });

    test('rifiuta frasi troppo corte o vuote', () {
      expect(isValidWakePhrase('ok'), isFalse);
      expect(isValidWakePhrase(''), isFalse);
      expect(isValidWakePhrase('!!'), isFalse);
      expect(isValidWakePhrase(null), isFalse);
    });

    test('rifiuta frasi troppo lunghe', () {
      expect(isValidWakePhrase('a' * (wakePhraseMaxChars + 1)), isFalse);
    });
  });

  group('varianti', () {
    // il riconoscitore del telefono scrive in italiano quello che sente:
    // "Jarvis" diventa "già visto". Non potendo suggerirgli la grafia (a
    // differenza del PC), l'utente elenca le forme separate da virgola.
    test('separate da virgola e normalizzate', () {
      expect(phraseVariants('jarvis, già visto , Ciarvis'),
          ['jarvis', 'gia visto', 'ciarvis']);
      expect(phraseVariants('jarvis, jarvis'), ['jarvis']);
      expect(phraseVariants(''), isEmpty);
    });

    test('basta una variante per riconoscere', () {
      const phrase = 'jarvis, già visto';
      expect(phraseInText(phrase, 'Già visto'), isTrue);
      expect(phraseInText(phrase, 'Jarvis'), isTrue);
      expect(phraseInText(phrase, 'andiamo al mare'), isFalse);
    });

    test('una variante troppo corta invalida tutta la frase', () {
      expect(isValidWakePhrase('jarvis, ok'), isFalse);
      expect(isValidWakePhrase('jarvis, già visto'), isTrue);
    });
  });

  group('ricerca solo in coda (durante la dettatura)', () {
    // mentre si detta, il telefono sente anche il testo dettato: cercare la
    // frase di stop in tutto il discorso la troverebbe in mezzo a una frase
    // qualsiasi, interrompendo la dettatura a meta'
    test('ignora la frase trovata a inizio discorso', () {
      const heard = 'jarvis stop e poi continuo a dettare un testo lungo';
      expect(phraseInText('jarvis stop', heard), isTrue);
      expect(phraseInText('jarvis stop', heard, onlyTail: true), isFalse);
    });

    test('riconosce la frase alla fine del discorso', () {
      const heard = 'scrivi una mail a Marco per la riunione jarvis stop';
      expect(phraseInText('jarvis stop', heard, onlyTail: true), isTrue);
    });

    test('funziona anche su un discorso corto', () {
      expect(phraseInText('jarvis stop', 'jarvis stop', onlyTail: true), isTrue);
    });
  });

  group('tolleranza', () {
    test('conta le lettere da correggere, non la somiglianza', () {
      expect(editDistance('jarvis', 'jarvis'), 0);
      expect(editDistance('jarvis', 'giarvis'), 2);
      expect(editDistance('jarvis', 'arrivi'), 4);
      expect(editDistance('jarvis stop', 'jarvis top'), 1);
    });

    test('almeno un errore e\' sempre concesso', () {
      expect(maxEdits(3), greaterThanOrEqualTo(1));
      expect(maxEdits(6), 2);
      expect(maxEdits(11), 3);
    });

    test('parole italiane comuni non fanno scattare l\'attivazione', () {
      for (final parola in [
        'arrivo subito',
        'grazie mille',
        'ti avviso domani',
        'devo scrivere una mail',
        'arrivederci',
        'servizio clienti',
      ]) {
        expect(phraseInText('jarvis', parola), isFalse, reason: parola);
        expect(phraseInText('jarvis stop', parola), isFalse, reason: parola);
      }
    });
  });

  group('il caso segnalato', () {
    test('"Jarvis Top" ferma la dettatura', () {
      // il riconoscitore mangia la esse: deve valere comunque come frase di
      // stop, altrimenti la dettatura resta aperta
      expect(phraseInText('jarvis stop', 'Jarvis Top', onlyTail: true), isTrue);
    });
  });
}
