# Record and Paste — telecomando per Stenografa

App Android/iOS che fa da telecomando per il demone **Stenografa** in
esecuzione su un PC (Linux, macOS o Windows). Il telefono diventa due cose
insieme:

1. **un microfono remoto**: si tocca un pulsante, si detta, e il testo
   trascritto sul PC viene incollato nell'applicazione che in quel momento ha
   il focus;
2. **una pulsantiera**: griglie di pulsanti a schermo intero che eseguono sul
   PC scorciatoie da tastiera, sequenze di tasti, snippet di testo o l'avvio
   di applicazioni.

Il riconoscimento vocale, l'incolla e l'esecuzione dei tasti avvengono tutti
sul PC: l'app non registra nulla in locale e non parla con servizi esterni,
manda solo comandi al demone sulla rete locale.

Il demone vive in un repository separato (`stenografa/`, `daemon.py`): questo
README descrive l'app, e cita il demone dove serve a capire cosa succede
dall'altra parte.

---

## Indice

- [Primo avvio](#primo-avvio)
- [La schermata principale](#la-schermata-principale)
- [Tipi di pulsante](#tipi-di-pulsante)
- [Attivazione vocale](#attivazione-vocale)
- [Modalità modifica](#modalità-modifica)
- [Dashboard](#dashboard)
- [Impostazioni](#impostazioni)
- [Controlli dei video](#controlli-dei-video)
- [Storico delle dettature](#storico-delle-dettature)
- [Sicurezza](#sicurezza)
- [Struttura del progetto](#struttura-del-progetto)
- [Sviluppo](#sviluppo)

---

## Primo avvio

Serve il demone già in esecuzione sul PC, sulla stessa rete locale del
telefono. Alla prima apertura l'app mostra la schermata di connessione, dove
vanno inseriti:

| Campo | Valore |
| --- | --- |
| Indirizzo IP del PC | es. `192.168.1.50` |
| Porta | `8765` (default del demone) |
| Token | 5 cifre, generate dal demone al primo avvio |

Il token si trova in `~/.config/stenografa/config.json` sul PC, ed è mostrato
anche in una notifica al primo avvio del demone. Il pulsante **Verifica
connessione** prova indirizzo, porta e token senza salvare nulla.

Da lì in poi l'app si ricollega da sola all'avvio e dopo ogni caduta di
connessione, riprovando ogni 3 secondi. Lo schermo resta acceso finché l'app è
in primo piano (serve da pulsantiera, non da app da consultare).

---

## La schermata principale

Una griglia di pulsanti a schermo intero. Lo swipe orizzontale passa da una
dashboard all'altra; i puntini sotto al nome indicano a che pagina si è.

Attorno alla griglia:

- **in alto a sinistra**: matita (modalità modifica), mirino ("segui app
  attiva") e storico quando c'e';
- **in alto al centro**: il nome della dashboard corrente;
- **in alto a destra**: le impostazioni.

**Segui app attiva** (il mirino): quando è acceso, l'app passa da sola alla
dashboard associata all'applicazione che ha il focus sul PC — se si porta in
primo piano GIMP compare la dashboard di GIMP. L'associazione si imposta per
ogni dashboard (campo "Rileva app").

In orizzontale la griglia viene ridisposta su tre colonne scorrevoli, così una
dashboard con molti pulsanti resta leggibile invece di rimpicciolirsi.

### Pulsanti più grandi

Un pulsante può occupare più di una cella. Il percorso è: **matita** in alto
a sinistra per entrare in modalità modifica, poi **tieni premuto** sul
pulsante finché non si apre "Modifica <nome>", e lì i due selettori
**Larghezza** e **Altezza** dicono quante celle prende in orizzontale e in
verticale. Vale per ogni tipo di pulsante, microfoni compresi. Serve a dare rilievo a
quelli che si premono più spesso — un "Registra" alto il doppio si trova al
buio senza guardare.

L'area occupata deve stare dentro la griglia e non sovrapporsi ad altri
pulsanti: se non c'è posto il PC rifiuta la modifica e lo dice, invece di
accavallarli. Per fare spazio si allarga prima la griglia con le barre
"righe"/"colonne". Trascinando, due pulsanti si scambiano di posto solo se
hanno la stessa forma.

### Colori e icona dell'applicazione

I pulsanti si colorano con una gamma di otto tinte — Corallo (l'accento),
Ambra, Oliva, Smeraldo, Ceruleo, Indaco, Magenta e Ardesia (il neutro di chi
non ha un colore proprio) — scelte per restare leggibili con l'etichetta
bianca sopra e per non litigare fra loro quando la griglia è piena.

Quando una dashboard è associata a un'applicazione del PC (perché contiene un
pulsante "Avvia applicazione" o perché ha un "Rileva app" che la identifica),
**l'icona vera di quell'applicazione** compare grande al centro dello
schermo, dietro la griglia, con un alone di luce che la stacca dal fondo. I
pulsanti sono leggermente traslucidi, così l'icona si intravede attraverso
di loro senza togliere leggibilità alle etichette: si capisce a colpo
d'occhio su quale dashboard ci si trova.

Anche i pulsanti "Avvia applicazione" mostrano l'icona vera dell'app al
posto del simbolo generico, così si riconoscono a colpo d'occhio. Se
preferisci un'icona diversa la scegli dall'editor: la tua scelta vince
sempre su quella automatica.

Le icone arrivano dal PC, non da internet: su Linux dai file `.desktop` e
dai temi di icone installati (l'SVG viene convertito in PNG quando serve),
su macOS dall'`.icns` dentro il bundle dell'app, su Windows dall'eseguibile
o dagli asset del pacchetto. Se un'applicazione non ne ha una, si ripiega
sul simbolo generico.

### Stato della dettatura

I pulsanti "microfono" cambiano aspetto seguendo lo stato del demone: grigio a
riposo, **rosso** durante la registrazione, ambra durante la trascrizione,
viola mentre l'IA elabora, azzurro mentre carica il modello. Il telefono vibra
a inizio e fine registrazione, perché il riscontro scritto del demone è una
notifica sul PC, cioè proprio dove non si sta guardando.

Una registrazione alla volta: mentre una è in corso, gli altri pulsanti
microfono si spengono e mostrano "Occupato da un altro pulsante". Solo quello
che l'ha avviata può fermarla, così il testo non finisce nel canale sbagliato
(una dettatura normale fermata dal pulsante IA, o viceversa).

---

## Tipi di pulsante

| Tipo | Cosa fa alla pressione |
| --- | --- |
| **Microfono** (`record`) | Avvia/ferma la dettatura; il testo trascritto viene incollato nella finestra col focus sul PC. |
| **Comando vocale IA** (`ai_command`) | Si detta un comando invece di un testo: un LLM locale (LM Studio sul PC) lo interpreta ed esegue la scorciatoia corrispondente — si dice "copia" e viene premuto Ctrl+C. Dà priorità alle scorciatoie della stessa dashboard. |
| **Scorciatoia** (`keys`) | Simula una combinazione di tasti, es. `ctrl+shift+z`. |
| **Macro** (`macro`) | Esegue in sequenza più combinazioni, con una pausa configurabile fra un passo e l'altro (max 20 passi). Se un passo fallisce la sequenza si ferma. |
| **Testo** (`text`) | Incolla uno snippet fisso: firme, prompt ricorrenti, percorsi lunghi (max 5000 caratteri). |
| **Avvia applicazione** (`launch`) | Avvia sul PC un'applicazione installata, scelta da un elenco. Il pulsante mostra **l'icona vera dell'applicazione** invece di un simbolo generico. |
| **Incolla ultimo** (`paste_last`) | Re-incolla l'ultima dettatura senza registrarne una nuova: serve quando il cursore non era dove doveva essere e il testo è finito nel posto sbagliato. |

L'incolla è adattivo: nei terminali il demone usa `Ctrl+Shift+V` invece di
`Ctrl+V`. Se l'incolla automatico non riesce, il testo resta comunque negli
appunti e il PC lo segnala.

### Invio automatico

Sul pulsante di registrazione c'è una **spunta "Invio"** in basso a destra:
quando è accesa, dopo aver incollato il testo dettato il PC preme **Invio**. In una
chat il messaggio parte da solo — detti e via, senza toccare la tastiera.

Si accende e si spegne con un tocco sulla spunta, senza entrare in modalità
modifica: è una scelta che cambia spesso, in chat serve e in un editor no.
Vale solo per quel pulsante e solo per la dettatura normale: il comando
vocale IA non incolla testo, e "Incolla ultimo" non preme mai Invio.

### Push-to-talk

Di default i pulsanti microfono funzionano da interruttore (tocca per
iniziare, tocca per fermare). Con il push-to-talk attivo registrano finché li
si tiene premuti — più comodo per le frasi brevi. Come rete di sicurezza il
demone ferma da solo una registrazione che supera i 3 minuti.

---

## Attivazione vocale

Avvia e ferma la dettatura pronunciando una frase, senza toccare il pulsante.
Si accende dalle impostazioni, sotto *Attivazione vocale*, dove ci sono **due
interruttori indipendenti** — si possono tenere accesi entrambi:

- **Ascolta dal PC**: è il demone a tenere aperto il microfono. È l'opzione
  più comoda: funziona anche col telefono in tasca o spento, e non consuma
  batteria.
- **Ascolta dal telefono**: l'app ascolta col microfono del telefono, usando
  il riconoscimento vocale di sistema. Funziona **con l'app aperta**. Utile
  quando si è lontani dal PC e il suo microfono non sentirebbe.

Le **due frasi** — una per avviare, una per fermare — si scrivono una volta
sola e valgono per entrambi gli ascolti (sono impostazioni del demone, quindi
seguono il PC e non il singolo telefono). Di default sono `jarvis` e
`jarvis stop`.

Conviene scegliere parole che non si direbbero per caso parlando: un nome
inventato funziona meglio di una parola comune. Servono almeno 3 lettere, e
le due frasi devono essere diverse fra loro. Il riconoscimento tollera gli
errori di trascrizione — fino a un quarto delle lettere — quindi "Jarvis Top"
vale come "Jarvis stop". Se le frasi finiscono nel testo dettato, il PC le
toglie da solo prima di incollare.

### Se il PC non ha la GPU

Se sul PC Whisper non può usare la scheda video (assente, driver mancanti o
VRAM occupata da altro), la trascrizione lì impiega all'incirca il tempo
reale. In quel caso **trascrive il telefono**, da solo e senza niente da
configurare: l'app usa il riconoscimento vocale di Android — lo stesso che sta
dietro al pulsante microfono della tastiera, ma senza tastiera a schermo — e
manda al PC il testo già pronto, che viene incollato come sempre.

Il testo arriva subito invece di farsi aspettare, ma la punteggiatura è più
povera e il vocabolario di dettatura non si applica: il riconoscitore di
Android non accetta suggerimenti. Serve l'app in primo piano, perché a sentire
è il microfono del telefono.

Quando la GPU torna disponibile si riprende a trascrivere sul PC.

### Se ti dimentichi di fermarla

Dopo dieci secondi senza sentirti parlare, la dettatura si chiude da sola e
incolla quello che ha raccolto — comodo proprio con l'attivazione vocale,
dove è facile dimenticare la frase di stop. L'attesa si cambia (o si
disattiva) da *Chiudi da sola dopo il silenzio* nelle impostazioni.

Non vale per il push-to-talk, dove è il dito a chiudere, e non scatta finché
la dettatura è più corta dell'attesa impostata: una registrazione appena
iniziata non viene chiusa solo perché non hai ancora aperto bocca.

### Quando la frase viene capita in un altro modo

Il riconoscimento vocale scrive quello che sente **nella lingua della
dettatura**: una parola inventata come "Jarvis", detta in italiano, diventa
spesso "già visto" o "ciarvis". Sul PC il problema è risolto suggerendo la
grafia al modello, ma il riconoscitore di Android e iOS non accetta
suggerimenti.

Per questo ogni casella accetta **più forme separate da virgola** — basta che
una combaci:

```text
Frase di avvio:  jarvis, già visto, ciarvis
Frase di stop:   jarvis stop, già visto stop
```

Sotto le caselle compare **l'ultima frase sentita**, distinta fra PC e
telefono: è lì che si legge come viene capita davvero, per poi aggiungerla.
Meglio non elencare espressioni che si usano spesso parlando ("già visto" lo
è): diventerebbero un modo per far partire la dettatura per sbaglio.

Mentre si detta, la frase di stop viene cercata solo in fondo a quello che il
telefono ha sentito: il microfono sente anche il testo che stai dettando, e
cercarla in tutto il discorso interromperebbe la dettatura a metà.

### I suoni di attivazione

Il trillo che si sente all'inizio e alla fine dell'ascolto è del riconoscitore
vocale di Android, e suona a ogni **sessione di ascolto**, non a ogni
dettatura. Le sessioni vengono chiuse e riaperte dal sistema anche quando
nessuno parla, quindi il telefono trilla a vuoto in continuazione.

Due accorgimenti, nell'ordine in cui sono stati necessari:

1. La sessione viene tenuta aperta a lungo (dieci minuti, in modalità
   "dettatura", che regge le pause) invece di richiuderla al primo silenzio.
   Riduce il numero di sessioni, ma non basta: Android le chiude comunque per
   conto suo.
2. I segnali acustici vengono **silenziati mentre si aspetta la frase** e
   ripristinati durante la dettatura, che è l'unico momento in cui dicono
   qualcosa di utile. Non esiste un modo ufficiale per chiedere al
   riconoscitore di tacere, quindi si mettono in muto gli stream audio su cui
   quei suoni finiscono (vedi `MainActivity.kt`): il silenzio copre perciò
   anche l'audio multimediale del telefono durante l'attesa. Si disattiva con
   *Silenzia i segnali acustici* nelle impostazioni.

Vengono ripristinati solo gli stream silenziati dall'app — se ne avevi già
messo uno in muto resta com'era — e il ripristino avviene anche se l'app viene
chiusa mentre l'ascolto è attivo.

Un'alternativa che sembra naturale — far partire il riconoscitore solo quando
si sente una voce — in pratica non funziona: il rilevatore scatterebbe
*durante* la parola, e il riconoscitore impiega qualche centinaio di
millisecondi ad avviarsi, sentendo solo la coda della frase di attivazione.

### Vedere che il PC sta registrando

Quando la dettatura parte a voce non si tocca niente, quindi il PC mostra da
solo un riquadro in basso allo schermo con un punto rosso che pulsa. Lo
disegna un'estensione GNOME installata insieme al demone: finché non è attiva
(su Wayland si carica al login successivo) non compare nulla. Vedi
"Attivazione vocale" nel README del demone.

Quando la frase di avvio viene riconosciuta, l'app preme per te il pulsante
microfono della dashboard aperta: la dettatura eredita quindi il vocabolario
della dashboard e l'invio automatico di quel pulsante, come se l'avessi
toccato. La frase di stop ferma solo una dettatura in corso.

Se almeno un ascolto è acceso, in alto a sinistra compare un'icona a
orecchio: serve a non lasciare un microfono aperto senza saperlo. Al primo
uso dell'ascolto dal telefono viene chiesto il permesso del microfono; se
viene negato l'app lo segnala, invece di lasciare l'interruttore acceso a
vuoto.

---

## Modalità modifica

Si entra con la matita in alto a sinistra. In questa modalità i pulsanti non
eseguono più le loro azioni: servono a essere riorganizzati.

- **Aggiungere**: si tocca una cella vuota e si sceglie il tipo di pulsante.
- **Spostare**: si trascina il pulsante su un'altra cella.
- **Eliminare**: la ✕ in alto a destra della cella. L'ultimo pulsante
  microfono del layout non è eliminabile, per non restare senza modo di
  dettare.
- **Modificare**: pressione prolungata su un pulsante. Da lì si cambiano
  **nome**, **azione** (combinazione di tasti, sequenza della macro con la sua
  pausa, snippet di testo), **colore** e **icona** — senza rifare il pulsante
  da zero, quindi mantenendone posizione e aspetto.
- **Ridimensionare la griglia**: le barre "righe" e "colonne" ai bordi
  aggiungono o tolgono celle.

---

## Dashboard

Ogni dashboard è una griglia indipendente, di solito dedicata a
un'applicazione del PC. Si passa dall'una all'altra con lo swipe.

In modalità modifica, toccando il **nome della dashboard** in cima si aprono le
sue opzioni: spostarla nell'ordine, duplicarla, eliminarla, o aprirne le
impostazioni:

- **Nome** — anche per rinominarla;
- **Rileva app** — il testo da cercare nel nome o nel titolo della finestra
  col focus sul PC (es. `code` per Visual Studio Code): è ciò che permette a
  "segui app attiva" di scegliere questa dashboard;
- **Vocabolario dettatura** — termini specifici di quell'applicazione (es.
  `InvokeAI, denoising, checkpoint`), usati per trascrivere correttamente il
  gergo quando si detta da un pulsante di questa dashboard.

Per **crearne una nuova**: matita → icona "+" nella barra a sinistra → nome →
Crea. (In alternativa, sempre in modalità modifica, si può scorrere con lo
swipe fino alla pagina "+" in fondo a tutte le dashboard.)

---

## Impostazioni

Raggiungibili dall'ingranaggio in alto a destra.

**Connessione** — indirizzo, porta, token, con verifica della connessione.

**Preferenze locali del telefono** (non condivise col PC):

- *Tieni premuto per parlare* — push-to-talk;
- *Vibrazione* — riscontro tattile a inizio/fine registrazione;
- *Segui app attiva* — si attiva anche dal mirino nella schermata principale;
- *Ascolta dal telefono* — attivazione vocale col microfono del telefono
  (vedi [Attivazione vocale](#attivazione-vocale)).

**Impostazioni del demone** (condivise: valgono per tutti i telefoni
collegati):

- *Lingua della dettatura* — 20 lingue più il rilevamento automatico;
- *Ripristina clipboard* — rimette negli appunti quello che c'era prima
  dell'incolla;
- *Traduzione automatica* — traduce il testo dettato prima di incollarlo, via
  Whisper (solo verso l'inglese) o via LLM locale (qualsiasi lingua);
- *Metti in pausa i video mentre detto* — ferma la riproduzione all'inizio
  della dettatura e la riprende alla fine (vedi
  [Controlli dei video](#controlli-dei-video));
- *Conferma prima di incollare* — il testo dettato compare sul telefono e si
  incolla solo dopo approvazione (modificabile prima dell'invio);
- *Vocabolario globale* — termini da trascrivere correttamente in ogni
  contesto;
- *Chiudi da sola dopo il silenzio* — dopo quanti secondi senza sentir parlare
  la dettatura si ferma e incolla da sé (10 di default, "Mai" per disattivarla);
- *Attivazione vocale* — l'ascolto sul PC e le due frasi che avviano e
  fermano la dettatura (vedi [Attivazione vocale](#attivazione-vocale));
- *Riavvia demone* — utile dopo un aggiornamento del suo codice, senza
  bisogno di un terminale sul PC.

**Sicurezza** — stato della connessione (cifrata o in chiaro), impronta del
certificato e interruttore *Richiedi TLS*.

---

## Controlli dei video

Quando sul PC c'è un video (o della musica), sotto l'ingranaggio compare un
piccolo pulsante per ogni flusso: **pausa** mentre suona, **play** quando è
fermo. Serve a fermare quello che sta suonando prima di dettare, senza
tornare alla tastiera — altrimenti il microfono ne capta l'audio e la
trascrizione ne esce rovinata — e a farlo ripartire quando si è finito.

Compaiono anche i video già in pausa, così aprendo l'app si trova comunque
il pulsante per farli ripartire. Le icone sono poche per costruzione: un
browser espone un player per finestra, non uno per scheda. Se più flussi
sono presenti compaiono più icone (fino a cinque); il tooltip mostra il
titolo di ciascuno, così si sa quale si sta fermando.

Il rilevamento usa **MPRIS**, lo standard D-Bus che espongono browser e
riproduttori su Linux (lo stesso su cui si appoggia KDE Connect). Su Windows
e macOS non è implementato e le icone non compaiono. Lo stesso video
pubblicato da più bus — capita con l'integrazione browser di Plasma — viene
mostrato una volta sola.

L'impostazione *Metti in pausa i video mentre detto* (spenta di default)
automatizza il tutto: il PC ferma da solo la riproduzione all'inizio della
dettatura e la riprende alla fine. Quello che è stato messo in pausa a mano
dal telefono non viene fatto ripartire dall'automatismo.

### Più schede che suonano insieme

I browser basati su Chromium (Chrome, Brave, Edge) pubblicano su MPRIS **un
solo player per finestra**, quello della scheda che sta suonando "in primo
piano" nella loro gestione interna: se due schede riproducono
contemporaneamente, la seconda non è visibile e non c'è modo di metterla in
pausa. È un limite del browser, non del demone — anche i widget multimediali
del desktop mostrano una sola scheda per browser.

Per quel caso, l'automatismo fa un secondo passaggio dai **flussi audio**:
PipeWire vede una traccia separata per ogni scheda che suona, quindi tutto
quello che i player non hanno fermato viene silenziato per la durata della
dettatura e riattivato alla fine. Il video continua a scorrere, ma muto,
quindi non finisce nella trascrizione. I flussi che erano già stati
silenziati a mano non vengono toccati.

---

## Storico delle dettature

L'icona dell'orologio, quando ci sono dettature, apre l'elenco delle ultime 20
(tenute solo in memoria dal demone, quindi si azzera al suo riavvio). Da lì si
può far re-incollare una voce passata: viaggia solo il suo identificativo, non
il testo, perché il demone accetta di incollare solo ciò che ha già prodotto.

Il pulsante "Incolla ultimo" è la scorciatoia alla voce più recente.

---

## Sicurezza

- **Token** a 5 cifre generato dal demone: senza, la connessione viene chiusa
  subito. Il demone blocca temporaneamente un IP dopo 5 tentativi falliti in
  60 secondi.
- **TLS con certificato self-signed** generato dal demone. Non essendoci
  un'autorità che lo garantisce, l'app usa il *trust on first use*: accetta il
  certificato visto al primo collegamento e da lì in avanti lo pretende
  identico. Se cambia (demone reinstallato, o qualcuno che si spaccia per il
  PC) la connessione si ferma e chiede una conferma esplicita, mostrando le
  due impronte a confronto.
- **Richiedi TLS**: il demone rifiuta le connessioni in chiaro. L'app non
  ricade mai in chiaro verso un PC di cui ha già fissato il certificato: un
  handshake fallito è un problema di rete e viene ritentato.
- Un rifiuto di autenticazione dice sempre *perché*: solo un token davvero
  sbagliato ferma i tentativi (va corretto a mano), mentre i rifiuti
  temporanei fanno riprovare da sola.

---

## Struttura del progetto

```text
lib/
├── main.dart                    tema e avvio
├── models/
│   ├── button_spec.dart         ButtonSpec, Dashboard, icone e colori
│   ├── connection_settings.dart indirizzo, porta, token
│   └── daemon_state.dart        stati del demone (idle, recording, …)
├── screens/
│   ├── home_screen.dart         griglia, modalità modifica, dialoghi
│   ├── settings_screen.dart     connessione e preferenze
│   └── history_screen.dart      ultime dettature
├── services/
│   ├── steno_client.dart        client TCP/TLS e protocollo JSON
│   ├── settings_service.dart    preferenze locali (SharedPreferences)
│   ├── wake_word_service.dart   ascolto della frase di attivazione
│   ├── wake_phrase.dart         confronto tollerante delle frasi
│   └── locale_service.dart      lingua dell'interfaccia
└── l10n/strings.dart            testi in italiano e inglese
```

### Il protocollo in breve

Righe JSON separate da `\n` su TCP (cifrate se il demone ha un certificato).
Il telefono manda per primo `{"cmd":"auth","token":"…"}`; dopo la risposta
`{"type":"auth","ok":true}` riceve stato, layout, configurazione e storico, e
può inviare comandi (`button`, `add_button`, `edit_button`,
`create_dashboard`, …). Gli aggiornamenti arrivano come messaggi `state`,
`layout`, `result`, `history`, `active_app`. La definizione autorevole è in
`daemon.py`.

---

## Sviluppo

```bash
flutter pub get
flutter run                 # su un telefono collegato
flutter analyze
flutter test
```

### Screenshot senza telefono

`test/screenshots_test.dart` monta la schermata principale con un client
riempito a mano e salva dei PNG in `test/goldens/`, senza bisogno di device né
emulatore:

```bash
flutter test --update-goldens test/screenshots_test.dart
```

Coprono la griglia a riposo, la registrazione in corso con gli altri microfoni
bloccati, i controlli dei video, l'editor del pulsante, le opzioni e le
impostazioni della dashboard e la creazione di una dashboard. Le immagini dipendono dalle font di sistema,
quindi una differenza nel confronto automatico non è necessariamente una
regressione.
