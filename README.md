# call-whisper

Transkrypcja rozmów **w czasie rzeczywistym** do Markdownu z timestampami per osoba.
Dwa niezależne tryby, oba lokalne — audio nigdzie nie wychodzi.

```markdown
**[00:00:04] Anna Kowalska**

Cześć wszystkim, zaczynamy standup.

**[00:00:11] Jan Nowak**

Hej, słychać mnie?
```

## Dwie wersje: natywna macOS i rozszerzenie Chrome

Od 2026-09-06 repo ma **aplikację natywną pod macOS** (`macos/`) obok
dotychczasowego rozszerzenia (`extension/`). Obie zapisują ten sam format
i dzielą tę samą logikę — rdzeń jest przepisany na Swift 1:1, a testy pilnują,
żeby liczby się zgadzały (o tym niżej).

```bash
npm run mac:build     # składa macos/build/call-whisper.app
open macos/build/call-whisper.app
```

Wymaga macOS 26 i Xcode 26 (Swift 6.2). Zero zależności zewnętrznych — tak jak
w wersji webowej: wszystko, czego potrzeba, jest w systemie.

### Co wersja natywna robi lepiej

| | rozszerzenie Chrome | **aplikacja macOS** |
| --- | --- | --- |
| Źródło dźwięku | tylko karta Chrome (`tabCapture`) | **dowolna aplikacja** — Zoom, Teams, Slack, FaceTime |
| ASR (polski) | whisper.cpp, serwer ręcznie | whisper.cpp, **serwer startuje sam** |
| FFT | pisana ręcznie w JS | Accelerate (vDSP) |
| Klucz API | `chrome.storage.local` | **Keychain** |
| Nakładka | Shadow DOM, walka z CSS strony | `NSPanel`, nie kradnie fokusu rozmowie |
| Diagnostyka | konsola przeglądarki | `--listen`, `--whisper`, `--probe` w terminalu |

### Plug and play: co aplikacja załatwia sama

Cel jest prosty — otwierasz i działa. Aplikacja sprawdza gotowość **przy
otwarciu okna**, a nie dopiero komunikatem błędu po kliknięciu „Słuchaj", i to,
co da się zrobić bez pytania, robi sama.

| | kto to załatwia |
| --- | --- |
| Model mowy (465 MB) | **aplikacja pobiera sama**, z paskiem postępu |
| `whisper-server` | wykrywa i podaje polecenie do skopiowania |
| Zgoda na nagrywanie ekranu | przycisk otwierający właściwy panel Ustawień |
| Podpowiedzi AI | wykrywa CLI Claude Code, działa bez klucza API |
| Uruchomienie serwera whispera | **aplikacja podnosi go sama** przy starcie nasłuchu |

Panel gotowości jest pod ikoną ✓ na pasku narzędzi i pokazuje się sam, gdy
czegoś brakuje.

Model można też pobrać z terminala:

```bash
npm run mac:fetch-model small        # 465 MB, domyślny
npm run mac:fetch-model large-v3-turbo
```

Pobieranie idzie przez `URLSessionDownloadTask`, a nie przez
`URLSession.bytes` — ten drugi oddaje strumień bajt po bajcie i na 148 MB
spalał 12 s czasu procesora na samą pętlę zamiast 1,3 s.

### Czego nie udało się uprościć

**Whisper.cpp musi być zainstalowany osobno** (`brew install whisper-cpp`).
Próbowałem spakować go do `.app` — domknięcie bibliotek to tylko 2,7 MB, ścieżki
dają się przepisać na `@executable_path`, a podpis da się ujednolicić. Blokadą
okazało się co innego: ggml ładuje backendy (Metal, CPU per generacja) jako
osobne `.so` z katalogu, który Homebrew ma **wkompilowany na stałe**
w `libggml-base`. Ani `GGML_BACKEND_PATH` (przyjmuje pojedynczy plik, nie
katalog), ani położenie ich obok binarki tego nie obchodzi — serwer wstaje
z `backends = 0` i wywala się w `make_buft_list`.

Obejściem byłoby zbudowanie whisper.cpp ze źródeł z własną ścieżką backendów.
To jednak ciężka zależność build w repozytorium, którego całą tożsamością jest
zero zależności i zero kroku build — więc świadomie zostaje `brew`.

### Silnik mowy: dlaczego whisper, a nie Apple

Naturalny odruch przy przepisywaniu na natywne to sięgnąć po `SpeechAnalyzer`
z macOS 26 — on-device, bez serwera, ze znacznikami czasu słów. Zrobiłem tak
i **to była zła decyzja**, z jednego twardego powodu:

```
SpeechTranscriber.supportedLocales -> 30 pozycji
de_AT de_CH de_DE en_AU en_CA en_GB en_IE en_IN en_NZ en_SG en_US en_ZA
es_CL es_ES es_MX es_US fr_BE fr_CA fr_CH fr_FR it_CH it_IT ja_JP ko_KR
pt_BR pt_PT yue_CN zh_CN zh_HK zh_TW
```

**Polskiego tam nie ma.** I nie zapowiada się, żeby był.

Gorzej: API pozwala tego nie zauważyć. `SpeechTranscriber.supportedLocale(equivalentTo:)`
dla `pl-PL` grzecznie zwraca `pl_PL`, choć modelu dla polskiego nie ma. Sprawdzenie
obsługi trzeba więc robić wprost przeciwko `supportedLocales` — inaczej start
rozpoznawania „udaje się", a błąd wychodzi dopiero w trakcie rozmowy.

Dlatego **domyślnym silnikiem jest whisper.cpp**, ten sam, którego używa
rozszerzenie i ten sam, dla którego zmierzone są liczby w tym README. Aplikacja
sama podnosi `whisper-server` przy starcie nasłuchu — rozszerzenie nie mogło,
bo wtyczka Chrome nie uruchamia procesów; aplikacja natywna może, więc `npm run
whisper` przestaje być osobnym krokiem.

`SpeechAnalyzer` zostaje jako druga opcja dla tych 30 języków: nie potrzebuje
serwera i daje znaczniki czasu wyniku, więc wiązanie tekstu z mówcą przestaje
być zgadywaniem okna. Ustawienia → Mowa → Silnik.

Wymagania whispera:

```bash
brew install whisper-cpp
mkdir -p ~/.cache/whisper-models
curl -L -o ~/.cache/whisper-models/ggml-small.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
```

Sprawdzenie całego łańcucha bez interfejsu:

```bash
# transkrypcja pliku: podnosi serwer, mierzy round-trip
call-whisper --whisper nagranie.wav

# nasłuch systemu przez 30 s, Markdown na stdout
call-whisper --listen 30
```

### Rozpoznawanie mówcy jest domyślnie wyłączone

Diaryzacja została w kodzie i działa, ale **domyślnie jej nie używamy** —
po pierwszym dłuższym nagraniu widać dlaczego. Klastrowanie MFCC to podejście
sprzed ery sieci neuronowych: przy kilku podobnych głosach jedna osoba rozsypuje
się na pięć etykiet i transkrypt wygląda tak:

```
Osoba obok 3  00:00:25   Auschwitz oraz Auschwitz Bierkanau.
Rozmówca 2    00:00:28   Auschwitz oraz Auschwitz-Birkanau.
Osoba obok 5  00:00:34   *w tle śpiew*
```

Etykiety, które się mylą, psują notatkę bardziej niż ich brak. Zostaje więc
podział, który jest **pewny i nic nie zgaduje**: mikrofon to „Ty", dźwięk
systemu to „Rozmówcy". Ten działa niezależnie od diaryzacji, bo bierze się
z rozdzielenia źródeł, a nie z analizy barwy głosu.

Domyślnie i tak słuchamy **tylko dźwięku systemu**: przy odsłuchu na głośnikach
mikrofon nagrywa to samo z opóźnieniem, a wtedy każda wypowiedź jest
w transkrypcie dwa razy i to w dwóch różnych, równie błędnych wersjach.

Efekt uboczny jest miły: MFCC liczone dla każdej ramki co 10 ms to najdroższa
część pętli, a bez niej zostaje sam VAD na energii.

Włączyć można w Ustawieniach → Mowa → „Rozpoznawaj, kto mówi". Ma to sens
tam, gdzie głosy są wyraźnie różne — a nie tam, gdzie w tle leci film.

### Zatrzymanie ma być natychmiastowe

Pierwsza wersja `stop()` dokańczała robotę: przetrawiała cały bufor wejściowy
i domykała otwartą wypowiedź, czyli wysyłała jeszcze jedno żądanie do whispera
na nawet 45 s audio. Przycisk zostawał w „Zatrzymaj" przez kilkanaście sekund
i wyglądał na zawieszony.

Teraz najpierw gaśnie stan widoczny w interfejsie, potem lecą anulowania —
bufor, timer, żądanie w locie, pytania do modelu. Zmierzone: **66 ms**. Tekst,
który już dojechał, zostaje w transkrypcie; ten ostatni, niedokończony, ginie
i to jest świadomy wybór.

### Jakość transkrypcji: co naprawdę pomogło

Zmierzone 2026-09-06 na polskim materiale z nazwami własnymi — udział błędnych
słów względem znanego tekstu, ten sam plik, ciepły serwer:

| konfiguracja | błędne słowa | czas |
| --- | ---: | ---: |
| `small`, zachłannie, bez promptu | 26,7 % | 696 ms |
| `small`, beam 5, bez promptu | 23,3 % | 896 ms |
| **`small`, beam 5, z promptem** | **13,3 %** | 929 ms |
| `large-v3-turbo`, beam 5, z promptem | 10,0 % | 1570 ms |

**Największą pojedynczą poprawę daje `prompt`, nie model ani beam search.**
Kontekst rozmowy niemal połowi liczbę błędów kosztem 33 ms, bo nakierowuje
dekoder na słownictwo, które w tej rozmowie już padło. Whisper przestaje
zgadywać nazwy własne od zera: `A uschwid zbirkę na ubył` staje się
`Auschwitz Birkenau był`.

Trzymamy więc przetaczane 400 znaków domkniętych wypowiedzi i podajemy je jako
`initial_prompt` przy każdym żądaniu.

Turbo dokłada jeszcze 3,3 punktu, ale kosztuje 1,6 s na rundę i 1,6 GB pamięci —
jest w wyborze modeli, domyślnie zostaje `small`.

Dekoder ma dwa profile, bo rundy służą do czego innego:

- **przyrostowe** (co 1,2 s) — zachłannie, bez beam search. Tekst ma się
  pojawić szybko i tak go za chwilę podmienimy.
- **ostateczna** (przy domknięciu wypowiedzi) — beam 5. To ona zostaje
  w notatce.

Widać to w działaniu: w trakcie mówienia leci `A uschwid zbiórkę na ubył na…`,
a po domknięciu wypowiedzi tekst podmienia się na pełny i poprawny.

Dodatkowo `suppress_nst` odsiewa `[Muzyka]` i `*w tle*` po stronie modelu,
zamiast czyścić je regexem po fakcie.

### Wyścig o wypowiedź, czyli znikające zdania

Najgorszy błąd tego łańcucha nie wywalał niczego — po prostu gubił zdania,
i to nie za każdym razem.

`closeUtterance` trzymał domykaną wypowiedź w polu współdzielonym i zerował je
dopiero na końcu, po dwóch punktach zawieszenia (czekanie na rundę w locie
i na transkrypcję ostateczną). W tym czasie ruszała już następna tura
i zapisywała tam **swoją** wypowiedź — którą to zerowanie kasowało.

W śladzie widać to wprost:

```
zamykam turę 12080..15000
...ale nie ma otwartej wypowiedzi      <- wypowiedź skasowana przez poprzednią turę
```

Objawy były dwa i oba wyglądały na kaprys whispera: część zdań w ogóle nie
trafiała do transkryptu, a część zostawała na surowej rundzie przyrostowej
(`To jest przybliżony szkid.` zamiast `To jest przybliżony szkic mapy GTA 6.`).

Naprawa jest jednozdaniowa: **wypowiedź przejmujemy natychmiast, przed
jakimkolwiek `await`**, i dalej pracujemy na kopii lokalnej. Rundy przyrostowe
sprawdzają przed zapisem, czy klucz wypowiedzi wciąż się zgadza — inaczej wynik
dotyczy czegoś, czego już nie ma.

Na kontrolnym nagraniu (cztery zdania z pauzami, trzy przebiegi pod rząd):
**12 tur, 12 wersji ostatecznych, 12 segmentów, zero zgubionych zdań.**

Przy okazji dwie rzeczy pomniejsze:

- **`minAudioMs` z 700 na 1400 ms.** Na sekundzie audio whisper chętnie zmyśla
  całe zdanie — a zmyślony tekst wchodzi potem do kontekstu i ciągnie się przez
  resztę wypowiedzi.
- **Anulowana runda przestała udawać awarię.** `URLSession` przy anulowaniu
  rzuca `URLError(.cancelled)`, a nie `CancellationError`, więc każda runda
  przerwana domknięciem wypowiedzi meldowała się jako „whisper-server nie
  działa" i zostawała w interfejsie jako błąd, którego nie było.

### Trzy błędy, przez które wersja ostateczna nigdy nie powstawała

Profile jakości nie działały, dopóki nie wyszły trzy rzeczy naraz — każda
wystarczała, żeby wypowiedź nigdy nie dostała ostatecznej transkrypcji.

**Potok, którego nikt nie czyta.** `whisper-server` dostawał `Pipe` na
stdout/stderr. Bufor potoku ma 64 kB, a serwer loguje każde żądanie — po
kilkudziesięciu sekundach proces **blokował się na zapisie**. Wyglądało to na
padnięcie serwera w połowie rozmowy. Wyjście idzie teraz do
`~/Library/Logs/call-whisper/whisper-<port>.log`.

**Pętla czekająca na własne zadanie.** `tick()` czekał na zakończenie żądania,
a pętla czekała na `tick()`. Jedno zawieszone żądanie zatrzymywało więc wszystko
— łącznie z wykrywaniem ciszy. Teraz żądanie leci obok, a kolejny tick po prostu
widzi, że poprzednie jeszcze trwa, i odpuszcza.

**Cisza, której nie ma w strumieniu.** ScreenCaptureKit nie wysyła buforów, gdy
w systemie panuje cisza — VAD nie dostaje wtedy cichych ramek i nie domyka tury.
Wypowiedź wisiała otwarta i kończyła się na ostatniej rundzie przyrostowej
z modelu szybkiego. Po 800 ms bez dźwięku domykamy turę sami.

Efekt tych trzech napraw razem, na tym samym nagraniu: **73,3 % → 13,3 %
błędnych słów.**

### Dwie osie czasu, czyli skąd biorą się ucięte wypowiedzi

Ten łańcuch ma dwa zegary i obie pomyłki w ich mieszaniu kosztowały całą
wypowiedź — a żadna nie rzuciła wyjątku.

**Bufor kołowy i diaryzator żyją w czasie próbek.** Bufor trzyma próbki ciągiem,
więc przerwy w dostawie dźwięku po prostu w nim nie istnieją.

**`TranscriptStore` żyje w czasie sesji**, bo tym zegarem mierzy ciszę.

Pierwsza pomyłka: liczyłem czas paczek audio z licznika próbek.
ScreenCaptureKit **nie wysyła buforów, gdy w systemie panuje cisza**, więc
licznik zostawał w tyle za zegarem — po ośmiu sekundach ciszy wypowiedź lądowała
w transkrypcie ze znacznikiem `00:00:00`. Naprawa: znacznik prezentacji
z `CMSampleBuffer` (prawdziwy zegar przechwytywania, uwzględnia przerwy),
zakotwiczony w czasie startu sesji, plus jawne przeliczenie czasu próbek na czas
sesji na granicy między buforem a store'em.

Druga pomyłka jest ciekawsza, bo wynikała z prawidłowego kodu użytego nie tam,
gdzie trzeba. `finalizeIdle` domyka segmenty, w których tekst przestał się
zmieniać — to ma sens dla źródeł napisowych, gdzie o ciszy dowiadujemy się
wyłącznie po tym, że tekst stoi w miejscu. Przy whisperze jest odwrotnie:
granice wypowiedzi wyznacza VAD, a każda runda przyrostowa dotyczy **tej samej**
wypowiedzi i niesie ten sam znacznik jej początku. `updatedAt` więc nie rosło,
segment był uznawany za martwy po 2,5 s, trafiał do `retired` — i każda kolejna,
dłuższa i lepsza wersja tekstu była po cichu odrzucana.

Objaw: w transkrypcie zostawał wyłącznie pierwszy fragment, ten sprzed 1,2 s.

```
[pipe] whisper(part)  -> "Zastanawiamy się nad polityką."          <- tylko to
[pipe] whisper(part)  -> "Zastanawiamy się nad polityką backupów…"     przechodziło
[pipe] whisper(final) -> "Zastanawiamy się nad polityką backupów dla bazy…"
```

Stąd `CW_DEBUG=1`: bez podglądu surowych aktualizacji diagnoza sprowadza się do
zgadywania, czy tekst gubi łańcuch, czy store.

### Skąd wiadomo, że port jest wierny

Rdzeń (tekst, transkrypt, Markdown, wykrywanie pytań, MFCC, VAD, diaryzacja)
został przepisany na Swift ręcznie — a to jest dokładnie ten rodzaj pracy,
w którym cicha rozbieżność jest łatwiejsza niż jawny błąd. Dlatego asercji nie
przepisywaliśmy: **generujemy je z działającego kodu JS**.

```bash
npm run mac:fixtures   # macos/tools/gen-fixtures.mjs -> fixtures.json
npm run mac:test       # Swift musi trafić w te same liczby
```

Co jest przypięte:

- `reconcile`, `normalize`, `fold`, `formatOffset` — wynik znak w znak
- `detectQuestion` — ta sama pewność co do dziesiątego miejsca i ten sam powód
- `renderMarkdown` — dokument bajt w bajt, w obu językach
- **MFCC** — współczynniki w granicy 0,05 (JS liczy w `Float64`, Accelerate
  w `Float32`)
- **VAD** — wypowiedź otwiera się i zamyka w **tej samej ramce**
- **diaryzacja** — ta sama liczba mówców i te same etykiety tur (Anna → Jan →
  Anna to `0,1,0`), granice tur w granicy jednej ramki

Syntetyczne głosy po stronie Swifta odtwarzają arytmetykę JS na `Double` razem
z utratą precyzji przy mnożeniu powyżej 2^53 — inaczej sygnał wejściowy byłby
inny i porównanie nic by nie znaczyło.

Dodatkowo FFT z Accelerate jest sprawdzana względem naiwnej DFT, bo vDSP pakuje
wynik nietypowo (`realp[0]` to składowa stała, `imagp[0]` to Nyquist, całość
przeskalowana ×2) i pomyłka w rozpakowaniu daje widmo, które wygląda wiarygodnie.

### Podpowiedzi bez klucza API: most do Claude Code

**Domyślne źródło podpowiedzi to lokalne CLI Claude Code**, a nie API. Nie
wymaga klucza ani osobnych opłat — korzysta z subskrypcji, którą już masz.
To jedyna darmowa opcja, która nadąża za rozmową.

Zmierzone 2026-09-06 (Claude Code 2.1.263, macOS), czas do pierwszego tokenu:

| | pierwszy token |
| --- | ---: |
| zimny start | 3856–4508 ms |
| **ciepły proces** | **1055–2255 ms** |
| dla porównania: `openrouter-free` przez API | 5691 ms |
| dla porównania: `gemini-3.5-flash-lite` (płatny) | 812 ms |

Wąskim gardłem nie jest inferencja, tylko start procesu: konfiguracja,
autoryzacja, hooki, serwery MCP. Dlatego proces jest **rozgrzewany przy starcie
nasłuchu**, zanim padnie pierwsze pytanie. Z tego samego powodu **Haiku nie jest
szybszy od modelu domyślnego** — mediana 3276 ms vs 2709 ms, a Sonnet 4668 ms.

Uczciwie o zmienności: most jest **wolniejszy i mniej przewidywalny niż API**.
Zmierzone na pięciu kolejnych pytaniach z realnym kontekstem:

```
pytanie 1  4248 ms   <- zimny start, mimo rozgrzewki
pytanie 2  1213 ms
pytanie 3  1181 ms
pytanie 4  3076 ms   <- po wymianie sesji
pytanie 5  1179 ms
```

Na ciepło ~1,2 s, ale po każdej przerwie proces stygnie i pierwsze pytanie
kosztuje 3-4,5 s. Dla porównania `gemini-3.5-flash-lite` przez API trzyma
812 ms niezależnie od rytmu — kosztem klucza i opłat.

### Dlaczego sesja jest wymieniana, a nie jedna na całą rozmowę

Sesja CLI kumuluje historię, a nasze prompty i tak niosą własny kontekst
z transkryptu — więc ta historia jest czystym narzutem. Widać to wprost:

```
jedna sesja na wszystko:  1727 → 1200 → 1343 → 4659 → 6107 ms
```

Piąte pytanie kosztuje pięć razy tyle, co drugie, i rośnie dalej. Dlatego sesja
jest wymieniana co trzy pytania, a zapasowa rozgrzewana w bezczynności.

Próbowałem **świeżej sesji na każde pytanie** — wyszło wyraźnie gorzej
(4,5–8,6 s), bo ciągłe startowanie procesów `claude` konkuruje o procesor
z tym, który właśnie odpowiada. Rozgrzewanie zapasowej *równolegle*
z odpowiadaniem podnosiło czas pierwszego tokenu z 1,7 s do 4,5 s — dlatego
dzieje się dopiero po oddaniu odpowiedzi.

### Rozgrzewka, która nigdy się nie wykonywała

Most raportował 9 s do pierwszego tokenu przy każdym pytaniu, choć zmierzony
osobno dawał ~1 s. Przyczyna była w dwóch linijkach obok siebie:

```swift
try await bridge.start(model:)      // odpalało replenish() w oderwanym Task
Task { await bridge.warmup() }      // trafiało na podniesioną flagę i wychodziło
```

`start()` podnosił flagę „rozgrzewam", a wołany zaraz po nim `warmup()` widział
ją i wychodził **natychmiast, nie czekając na nic**. Rozgrzewka nigdy się nie
kończyła przed pierwszym pytaniem, więc każde pytanie płaciło zimny start.

Diagnoza była w logu przez cały czas i wyglądała niewinnie:

```
zimny start: 1 ms (nieudany)     <- rozgrzewka wróciła w 1 ms
```

Po naprawie `start()` tylko zapamiętuje konfigurację, a `warmup()` jest jedynym
miejscem, które podnosi proces — i czeka na zakończenie. Pierwsze pytanie:
**9723 ms → 994 ms**.

### Pytanie musi się kończyć tam, gdzie się kończy

Przy długiej, niepodzielonej wypowiedzi wycinane „pytanie" brało wszystkie
frazy od słowa pytającego **do końca segmentu** — czyli razem z odpowiedzią,
która po nim padła:

```
czy LazyColumn recyklinguje elementy tak samo jak RecyclerView, Nie do końca
tak samo, ale efekt jest podobny, LazyColumn tworzy kompozycję tylko dla…
```

Teraz koniec wyznacza pytajnik, a gdy go nie ma (mowa często go nie daje) —
najwyżej dwie frazy. To samo pytanie: 160 → 62 znaki.

### Mowa ciągła bez pauz

VAD domyka wypowiedzi na ciszy. Przy nagraniu z TTS, czytanym tekście albo
kimś mówiącym bez oddechu cisza nie nadchodzi i tura wisi otwarta. Zmierzone
na materiale bez pauz: **jeden segment na 1 minutę 43 sekundy**.

Po przekroczeniu 25 s domykamy więc wypowiedź sami — ale nie co do sekundy,
tylko w najbliższej cichej ramce, żeby nie rozerwać zdania w połowie. Gdy
przerwa nie nadejdzie przez kolejne 8 s, tniemy mimo wszystko.

To jest jednak tylko zabezpieczenie. **Nagranie testowe musi mieć pauzy** —
`test/fixtures/rozmowa-android-elevenlabs.txt` ma wstawione
`<break time="1.2s" />` po każdym akapicie.

### Zrzut ekranu w pytaniu

Do pytania można wkleić obrazek przez **⌘V** — albo spinaczem obok pola, jeśli
schowek już coś ma. Zrzut idzie do modelu razem z pytaniem, więc „co tu jest
nie tak?" nad wklejonym stack trace'em działa bez opisywania go słowami.
Samo pytanie może wtedy zostać puste.

Trzy rzeczy warte odnotowania:

- **CLI Claude Code przyjmuje obrazy w trybie stream-json** — blok
  `{"type":"image","source":{"type":"base64",…}}` w treści wiadomości. Sprawdzone,
  bo bez tego funkcja nie działałaby na domyślnym backendzie. Po stronie API
  idzie to jako `image_url` z `data:`-URI.
- **Obraz przed tekstem.** Anthropic zaleca taką kolejność bloków — model widzi
  wtedy, do czego odnosi się pytanie.
- **Skalujemy do 1568 px na dłuższym boku.** Zrzut z ekranu Retina to często
  3000 px i kilka MB; po base64 rośnie o kolejną jedną trzecią i prompt robi się
  wolniejszy niż sama odpowiedź, a modele i tak nie korzystają z wyższej
  rozdzielczości.

Zmierzone: pytanie ze zrzutem to ~3,7 s do pierwszego tokenu wobec ~1 s bez
obrazka. Timeout jest dla nich podniesiony do 120 s.

Sprawdzenie bez interfejsu:

```bash
macos/build/call-whisper.app/Contents/MacOS/call-whisper \
  --ask-image zrzut.png "Co tu jest nie tak?"
```

### Kontekst projektu, o którym rozmawiasz

Sam transkrypt to za mało, gdy rozmowa dotyczy konkretnego repozytorium.
Ustawienia → Ogólne → **Kontekst projektu** wskazuje plik z opisem: architektura,
decyzje, nazwy klas. Trafia do każdego pytania jako tło, przed transkryptem.

Domyślnie czytany jest `~/Library/Application Support/call-whisper/project-context.md`.
Limit 8000 znaków; dłuższy jest przycinany.

Efekt widać od razu — pytanie „czy swipe usuwa nawyk?" z kontekstem repo:

> Nie — swipe oznacza nawyk jako wykonany (w prawo) lub niewykonany (w lewo)
> na dziś, a kafelek wraca na miejsce, bo `confirmValueChange` zawsze zwraca
> `false`. Usuwanie jest wyłącznie w `ManageHabitsScreen`.

Koszt: 1452 ms do pierwszego tokenu przy kontekście na 5700 znaków, wobec ~1000 ms
bez niego.

**Pisz ten opis z kodu, nie z README.** Przy pierwszym takim dokumencie README
projektu okazał się nieaktualny w trzech miejscach — opisywał gest, którego kod
nie ma. Model powtórzyłby to bez mrugnięcia.

### Kolejka pytań jest płytka celowo

Przy monologu albo filmie wykrywacz pytań trafia co kilka sekund, a jedna
odpowiedź idzie 1,5–5 s. Bez ograniczenia bufor rósł, odpowiedzi przychodziły
do pytań sprzed pół minuty, a interfejs wyglądał na zawieszony.

Więc: **jedno pytanie na raz, nowsze wygrywa**, a pytania starsze niż 20 s są
porzucane. Odpowiedź na to, co padło przed chwilą, jest warta więcej niż na to
sprzed kilkunastu sekund. Karta odpowiedzi pokazuje licznik sekund, żeby było
widać, że coś się dzieje.

Trzy rzeczy warte odnotowania przy tej konstrukcji:

- **CLI emituje `system/init` dopiero PO pierwszym wejściu na stdin.** Czekanie
  na gotowość przed wysłaniem pytania zawiesza obie strony na zawsze —
  kolejka musi ruszyć od razu po starcie procesu.
- **Timeout wymaga restartu procesu.** CLI i tak dośle `result` dla porzuconego
  promptu, a nie ma jak go rozpoznać — trafiłby do *następnego* pytania.
- **stderr trzeba czytać**, choćby do kosza. Potok, którego nikt nie opróżnia,
  blokuje proces potomny po zapełnieniu 64 kB.

Narzędzia są wyłączone (`--disallowed-tools`): asystent ma odpowiadać, a nie
czytać ani zmieniać pliki. Proces startuje w katalogu tymczasowym, żeby kontekst
Twojego projektu nie wyciekał do odpowiedzi na pytania z rozmowy.

Sprawdzenie bez uruchamiania interfejsu:

```bash
macos/build/call-whisper.app/Contents/MacOS/call-whisper --ask "Jakie RPO daje snapshot co godzinę?"
# rozgrzewam most…
#   zimny start: 4508 ms (ok)
#   pierwszy token: 1055 ms, całość: 2107 ms
```

Płatne API zostaje jako druga opcja — jest szybsze (812 ms) i bardziej
przewidywalne, ale wymaga klucza. Ustawienia → Asystent → Źródło.

### Podpowiedzi: który model i dlaczego

Wersja natywna nie ma mostu do CLI Claude Code — odpytuje bezpośrednio API
zgodne z OpenAI (Experiential Labs). Katalog wystawia **313 modeli**, więc
wyboru nie da się zrobić z opisu. Zmierzone 2026-09-06: polskie pytanie
z kontekstem rozmowy, dwie serie po 5 przebiegów, mediana czasu do pierwszego
tokenu.

| model | pierwszy token | pełna odpowiedź | udanych prób |
| --- | ---: | ---: | ---: |
| **gemini-3.5-flash-lite** | **812 ms** | **1065 ms** | 10/10 |
| mercury-2 | 835 ms | 1043 ms | 9/10 |
| claude-haiku-4.5 | 893 ms | 2710 ms | 10/10 |
| gemini-3.1-flash-lite | 975 ms | 1805 ms | 10/10 |
| glm-4.7-flash | 1577 ms | 1764 ms | 10/10 |
| gemini-3.8-flash | 1603 ms | 1638 ms | 10/10 |
| openrouter-free | 5691 ms | 5832 ms | darmowy |
| minimax-m2.7-free | 11 541 ms | — | darmowy |

Domyślny jest **`gemini-3.5-flash-lite`**.

Dwie rzeczy, których nie widać w samej medianie:

- **Wariancja jest spora** — ten sam model potrafi dać 800 i 1800 ms. Różnice
  rzędu stu milisekund między czołówką są w granicach szumu, więc liczy się też
  górny ogon: `claude-haiku-4.5` ma dobrą medianę, ale raz na pięć razy
  odpowiadał po 2,7 s.
- **Długość odpowiedzi kosztuje.** `claude-haiku-4.5` zaczyna szybko, ale pisze
  najwięcej i kończy po 2,7 s. Przy podpowiedzi w trakcie rozmowy liczy się
  jedno i drugie.

`mercury-2` był domyślny wcześniej i jest praktycznie remisem — zgubił jedno
żądanie na dziesięć, więc ustąpił miejsca.

Kilka modeli z nazwą sugerującą szybkość okazało się nieużywalnych: `glm-5.3-flash`,
`qwen3.6-flash`, `seed-2.0-lite` i `nemotron-3.5-lightning` łączą się i kończą
strumień **bez żadnej treści**, a `gpt-5.4-nano` wymaga podpięcia własnego klucza
dostawcy.

Warto wiedzieć, co się kupuje za zero: **darmowy jest ~7× wolniejszy od
najszybszego płatnego** i bywa odrzucany błędem 429. Z ~9 modeli z sufiksem
`-free` w katalogu odpowiedziały **dwa**; reszta zwracała 429 także po pięciu
próbach z backoffem rozłożonych na kilkanaście minut. Dla porównania — most do
lokalnego CLI Claude Code dawał 1861 ms.

Klucz i model sprawdzisz bez uruchamiania interfejsu, tą samą ścieżką kodu,
której używa aplikacja:

```bash
npm run mac:probe gemini-3.5-flash-lite
# model: gemini-3.5-flash-lite
# OK — pierwszy token po 917 ms (ciepłe połączenie)
```

Pomiar rozgrzewa połączenie i mierzy dopiero drugie żądanie: pierwsze płaci
~0,5 s za zestawienie TLS, a w aplikacji klient żyje przez całą rozmowę, więc
ten koszt ponosi się raz i użytkownik go nie widzi.

### Klucz API: pułapka Keychaina przy podpisie ad-hoc

Zapis klucza wygląda na formalność, a ma dno, na które da się wpaść dwa razy
pod rząd.

**Raz.** Wpis założony z zewnątrz przez `security add-generic-password -T ""`
wygląda na liście poprawnie, ale `-T ""` daje pustą listę zaufanych programów,
czyli **nikt** go nie odszyfruje. Objaw jest mylący: aplikacja mówi „brak
klucza API", choć wpis fizycznie istnieje. Diagnoza:
`security find-generic-password … -w` zwraca `rc=128`.

**Dwa.** Wpis założony poprawnie, przez samą aplikację, dostaje ACL z regułą
`requirement: cdhash H"…"` — przypiętą do **hashu konkretnej binarki**. Przy
podpisie ad-hoc każda przebudowa daje nowy hash, więc po każdym
`npm run mac:build` system blokuje odczyt monitem o hasło.

Nowszy „data protection keychain" rozwiązałby to tożsamością aplikacji zamiast
hashem, ale bez Team ID jest zamknięty — `SecItemAdd` zwraca wtedy **-34018**
(`errSecMissingEntitlement`). Sprawdzone, nie zgadnięte.

Zostaje więc założenie wpisu z ACL, w którym lista zaufanych programów jest
`nil`, co w semantyce `SecACLSetContents` znaczy „wszystkie programy". Cena
jest realna i lepiej ją znać: **dowolny proces działający na Twoim koncie
odczyta ten klucz bez pytania.** To ta sama ekspozycja co plik 0600 w katalogu
aplikacji — nie ma tu piaskownicy, która dawałaby więcej. Nadal jest to lepiej
niż `chrome.storage.local` w wersji webowej, bo wpis jest szyfrowany na dysku
razem z login keychain.

Klucz najpewniej ustawisz ścieżką aplikacji, nie przez `security`:

```bash
npm run mac:build
macos/build/call-whisper.app/Contents/MacOS/call-whisper --set-key xpl_...
```

W interfejsie pole klucza ma osobny przycisk **Zapisz** i mówi wprost, czy
Keychain przyjął zapis. Wiązanie `SecureField` prosto do Keychaina zapisywało
klucz przy każdym naciśnięciu klawisza, a przy nieudanym zapisie pole gubiło
tekst w trakcie pisania — do magazynu trafiały wtedy niepełne klucze i wracało
`401 invalid_key`. Białe znaki są przycinane: wklejony klucz z końcem linii daje
nagłówek `Bearer xpl_…\n` i ten sam błąd, który wygląda na zły klucz, a jest
złym wklejeniem.

**Aktualizacja 2026-10-05: klucz jest w pliku, nie w Keychainie.** Otwarte
ACL nie wystarczyło. macOS sprawdza jeszcze listę partycji wpisu, a przy
podpisie ad-hoc jest w niej hash konkretnej binarki, więc po każdej przebudowie
pojawiał się monit „call-whisper potrzebuje dostępu do klucza
ai.callwhisper.apikey”. Gorzej, że klucz był czytany przy każdym wykrytym
pytaniu, także przy moście do Claude Code, który klucza nie potrzebuje, więc
monit wyskakiwał w środku rozmowy. Teraz klucz leży w
`~/Library/Application Support/call-whisper/api-key` z prawami 0600 (ta sama
ochrona, jaką dawało otwarte ACL) i jest czytany tylko dla backendu API. Stary
wpis z Keychaina przenosimy raz, i tylko gdy backendem jest API.

### Podpis: dlaczego ad-hoc nie wystarczy

Objaw jest podstępny: w Ustawieniach systemowych przełącznik przy
call-whisper w „Nagrywaniu ekranu i dźwięku systemowego" jest **włączony**,
a panel Gotowość i tak melduje „Zgoda na nagrywanie ekranu" na czerwono.

TCC (zgody na ekran i mikrofon) rozpoznaje aplikację po *designated
requirement* podpisu. Przy podpisie ad-hoc jest nim
`cdhash H"…"`, czyli skrót konkretnej binarki. Każde `npm run mac:build`
daje nowy skrót, więc zgoda dotyczy już nieistniejącej wersji, a nowej system
po cichu odmawia. Sprawdzenie:

```bash
codesign -d -r- macos/build/call-whisper.app
# ad-hoc:      designated => cdhash H"efb5…"                     <- zmienia się co build
# certyfikat:  designated => identifier "ai.callwhisper.mac" and certificate leaf = H"1e63…"
```

Bez konta Apple Developer wystarczy lokalny, samopodpisany certyfikat:

```bash
bash macos/tools/make-cert.sh      # raz: „call-whisper local" w pęku kluczy logowania
npm run mac:build                  # bundle.sh sam go wykrywa
tccutil reset ScreenCapture ai.callwhisper.mac
```

Po resecie trzeba raz włączyć zgodę od nowa i uruchomić aplikację ponownie;
potem przeżywa każdą przebudowę. Kolejność wyboru w `bundle.sh`: `CW_IDENTITY`,
certyfikat Apple (Development / Developer ID), „call-whisper local", a dopiero
na końcu ad-hoc, z ostrzeżeniem.

Dwie pułapki z samego skryptu:

- `find-identity -v` pomija samopodpisany certyfikat („nie zaufany",
  `CSSMERR_TP_NOT_TRUSTED`), choć `codesign` podpisuje nim bez problemu,
  więc `bundle.sh` szuka go bez `-v`.
- Plik p12 robi systemowe `/usr/bin/openssl` (LibreSSL). OpenSSL 3
  z Homebrew szyfruje p12 algorytmem, którego `security import` nie czyta.

Taki certyfikat działa tylko na tym Macu. Do rozdania aplikacji innym trzeba
Developer ID i notaryzacji.

### Podpowiedzi w notchu

Nakładka w rogu ekranu ma jedną wadę: wzrok ucieka od kamery i na rozmowie
widać, że czytasz. Notch jest dokładnie nad kamerą, więc podpowiedź czytana
stamtąd wygląda jak patrzenie rozmówcy w oczy. Stąd wyspa w stylu Dynamic
Island (Atoll, boring.notch), bez żadnej zależności:

- **nasłuch**: „uszy" po bokach notcha, kropka i czas rozmowy;
- **pytanie**: wyspa rozwija się w dół od razu, z „Myślę…", a odpowiedź
  napływa słowo po słowie, czcionką 16 pt;
- **po odpowiedzi** zostaje tyle, ile trwa przeczytanie jej na głos
  (~2,5 słowa na sekundę), potem się zwija. Kursor nad wyspą ją zatrzymuje,
  pinezka przypina, dwuklik w pasek włącza i wyłącza nasłuch.

Na ekranie bez notcha ta sama wyspa wisi jako pigułka pod paskiem menu.
Ustawienia → „Podpowiedzi w notchu".

Trzy rzeczy, których nie widać, a bez których to nie działało:

- `sharingType = .none`: wyspy nie ma na udostępnianym ekranie ani na
  nagraniu, więc rozmówca nie zobaczy podpowiedzi.
- **App Nap**: w rozmowie aplikacja jest w tle i macOS dławi jej timery
  i rysowanie. Zmierzone: 2,5 s czekania trwało 4,1 s, a wyspa stała na
  „Myślę…", choć odpowiedź już napływała. Nasłuch trzyma teraz
  `ProcessInfo.beginActivity(.latencyCritical)`, co pomaga też rundom
  transkrypcji.
- `.symbolEffect(.pulse, options: .repeating)` na iskierkach zatykał główny
  wątek panelu (2,5 s -> 6,2 s), a `NSHostingView` jako `contentView`
  zmieniający rozmiar co kilkadziesiąt ms kończył się wyjątkiem AppKit
  o pętli „Update Constraints". Iskierki są statyczne, a hosting view siedzi
  w kontenerze na autoresizingu.

Wygląd sprawdza się bez rozmowy:

```bash
call-whisper --notch-demo          # przejście przez wszystkie stany na ekranie
call-whisper --snapshot <katalog>  # stany wyspy jako PNG, obok okna głównego
```

### Nagrywanie razem z OBS

**Słuchaj** uruchamia OBS, jeśli nie działa, i włącza w nim nagrywanie.
**Zatrzymaj** kończy nagranie i zapisuje transkrypt obok pliku wideo, z tą
samą nazwą: `2026-10-05 22-30-00.mkv` dostaje sąsiada `2026-10-05 22-30-00.md`.
Znaczniki czasu liczą się od startu nagrania OBS, więc `[00:01:05]` w tekście
to 1:05 w filmie. Działa też odwrotnie: nagranie włączone ręcznie w OBS
włącza nasłuch, a jego stop kończy oba.

Połączenie idzie przez obs-websocket (wbudowany w OBS 28+), a port i hasło
call-whisper czyta z pliku konfiguracji OBS. Gdy OBS jest zamknięty,
call-whisper sam włącza w tej konfiguracji serwer WebSocket przed
uruchomieniem OBS. Działającemu OBS nie da się tego zmienić z zewnątrz, więc
wtedy trzeba raz kliknąć w OBS: **Narzędzia → Ustawienia serwera WebSocket →
Włącz serwer WebSocket**. Pliku konfiguracji, którego jeszcze nie ma,
call-whisper nie zakłada: serwer bez hasła słucha na wszystkich interfejsach.

Gdy OBS zawiedzie (brak programu, wyłączony serwer, brak odpowiedzi),
nasłuch i tak rusza, tylko bez wideo, a powód widać w oknie. Wyłącznik jest
w Ustawieniach, w sekcji OBS.

Ograniczenie: pauza w OBS nie jest uwzględniana, więc po wznowieniu czasy
w transkrypcie wyprzedzają film o długość pauzy.

### Czego wersja natywna jeszcze nie ma

- **Trybu napisów Meet.** Czytanie DOM-u Meeta wymaga bycia w przeglądarce,
  więc ten tryb zostaje w rozszerzeniu — i tam nadal jest dokładniejszy,
  bo imiona są prawdziwe.
- **Backendu Groqa.** Whisper lokalnie jest darmowy i szybszy, a audio nie
  opuszcza urządzenia — Groq zostaje w wersji webowej dla maszyn słabszych niż
  Apple Silicon.

## Cztery silniki

| | **Napisy Meet** | **whisper.cpp lokalnie** | **Chrome, lokalnie** | **Groq Whisper** |
| --- | --- | --- | --- | --- |
| Źródło | napisy Meet z DOM | dźwięk karty + mikrofon | jw. | jw. |
| Kto mówi | strumień uczestnika (bezbłędnie) | **diaryzacja, chunk = jeden mówca** | diaryzacja + zgadywanie okna | diaryzacja, chunk = mówca |
| Opóźnienie | zero | **~1,5 s, stałe** | 1–3 s | ~2 s po końcu wypowiedzi |
| Prywatność | lokalnie | **lokalnie** | lokalnie | audio leci do Groqa |
| Koszt | — | — | — | $0,04–0,111 / h |
| Wymaga | — | `npm run whisper` | modelu SODA | klucza API |

**Domyślnie bierz `whisper.cpp lokalnie`** — jest najszybszy, darmowy i nic nie
wychodzi z urządzenia. Groq zostaje dla maszyn bez whisper.cpp albo słabszych
niż Apple Silicon.

Na Meecie zostaw tryb napisów — jest dokładniejszy i lżejszy, a imiona są
prawdziwe. Tryb głosu bierz tam, gdzie napisów nie ma: Zoom, Teams, Slack
huddle, podcast w karcie, albo sala konferencyjna z jednym mikrofonem, gdzie
Meet i tak przypisałby wszystkich do jednej osoby.

W trybie głosu wybór silnika to wybór między prywatnością a jakością. Groq jest
wyraźnie dokładniejszy, ale audio opuszcza urządzenie — więc jest domyślnie
wyłączony i wymaga wklejenia własnego klucza API.

Wszystkie silniki zapisują do tego samego formatu i tej samej sesji.

## Skąd bierze się szybkość

Wszystkie liczby zmierzone na **Apple M4**, 5 s polskiej mowy, ciepły serwer.

### 1. Transkrypcja przyrostowa — największy zysk

Wcześniej czekaliśmy, aż VAD domknie wypowiedź, i dopiero wtedy wysyłaliśmy
audio. To znaczy, że przy dwudziestosekundowej wypowiedzi tekst pojawiał się po
dwudziestu sekundach — **latencja rosła z długością mówienia**.

Teraz co 1,2 s transkrybujemy wypowiedź od jej początku do teraz i podmieniamy
tekst segmentu. Zmierzone na 8,8 s polskiej mowy, ten sam backend:

| | pierwszy tekst | tekst końcowy |
| --- | ---: | ---: |
| czekaj na koniec wypowiedzi | 9543 ms | 9543 ms |
| **przyrostowo** | **1541 ms** | 9454 ms |

**6,2× szybciej** — i to niedoszacowanie, bo stara latencja rosła z długością
wypowiedzi, a nowa jest stała.

Wygląda to na marnotrawstwo (transkrybujemy to samo audio wielokrotnie), ale
nie jest — z powodu poniżej.

### 2. Encoder Whispera kosztuje tyle samo niezależnie od długości audio

| audio | encode |
| --- | ---: |
| 3 s | 947 ms |
| 5 s | 924 ms |
| 8,75 s | 922 ms |

Wejście jest zawsze dopychane do okna 30 s, więc trzysekundowa wypowiedź
kosztuje tyle co trzydziestosekundowa. Dlatego ponowne transkrybowanie tej samej
wypowiedzi co sekundę jest tanie — i dlatego pkt 1 w ogóle się opłaca.

### 3. Model `small` bije `large-v3-turbo` czterokrotnie

| model | encode | **round-trip HTTP** | jakość (polski) |
| --- | ---: | ---: | --- |
| base (141 MB) | 187 ms | ~300 ms | „chciałbym **o mówić**" — błąd |
| **small (465 MB)** | 188 ms | **396 ms** | poprawnie, z interpunkcją |
| large-v3-turbo (1,6 GB) | 902 ms | ~1,4 s | poprawnie |

`base` ma ten sam encode co `small`, więc nie ma powodu go używać. `small` jest
domyślny.

### 4. Model musi zostać załadowany

`whisper-cli` płaci ~400 ms na wczytanie modelu przy każdym uruchomieniu.
`whisper-server` trzyma go w pamięci — ta sama lekcja, co przy moście do Claude
Code, gdzie start procesu kosztował więcej niż inferencja.

### Czego nie wybrałem i dlaczego

- **Parakeet MLX** — szybszy od Whispera na papierze (RTFx 3386), ale
  raportowane ~22 GB pamięci zunifikowanej nie zmieści się w 16 GB tej maszyny.
- **Deepgram Flux / AssemblyAI / Soniox** — prawdziwy streaming po WebSockecie,
  ~100–300 ms latencji, czyli szybciej niż nasze 1,5 s. Odpadły, bo audio
  wychodzi na zewnątrz i są płatne; przy lokalnym whisperze nie ma za co płacić.
- **whisper_streaming (LocalAgreement)** — elegancki sposób na commitowanie
  tekstu bez czekania na koniec wypowiedzi, ale wymaga znaczników czasu słów
  i buforowania. Nasze podejście „transkrybuj wypowiedź od początku i podmień"
  daje ten sam efekt przy ułamku złożoności, bo `TranscriptStore` już umie
  podmieniać tekst (`replace`).

## Tryb asystenta: Claude podpowiada w trakcie rozmowy

Wykrywa pytania w transkrypcji i odpowiada w nakładce na stronie rozmowy —
przez **Twój lokalny CLI Claude Code**, bez osobnego klucza API.

```bash
npm run assistant          # most do CLI, zostaw uruchomiony
```

Potem popup → ⚙ → **Podpowiadaj w rozmowie**.

Pytanie można też wpisać albo wkleić wprost w nakładce — Enter wysyła,
Shift+Enter łamie wiersz. Takie pytanie omija wykrywanie i ustawienie „pytaj
automatycznie", ale kontekst z transkrypcji dostaje ten sam, więc „a ile to
kosztuje?" wie, o czym była mowa. Klawisze nie opuszczają nakładki: strona pod
spodem trzyma własne skróty na całym dokumencie i bez tego pisanie sterowałoby
rozmową.

### Dlaczego proces musi być ciepły

Zmierzone na Claude Code 2.1.241, macOS — czas do **pierwszego tokenu**:

| | zimny start | ciepły proces |
| --- | ---: | ---: |
| model domyślny | 3938 ms | **804 ms** |
| Haiku 4.5 | 4738 ms | 1706 ms |

Dwa wnioski, oba wbrew intuicji:

1. **Wąskim gardłem nie jest inferencja, tylko start procesu** — konfiguracja,
   autoryzacja, hooki, serwery MCP. Dlatego Haiku nie jest szybszy od modelu
   domyślnego; przy zimnym starcie jest wręcz wolniejszy.
2. **Haiku przegrywa też na ciepło.** Nie warto schodzić z modelu dla samej
   szybkości.

Stąd konstrukcja: jeden proces `claude` żyje przez całą rozmowę i jest
rozgrzewany przy starcie mostu, zanim padnie pierwsze pytanie.

Uwaga, której nie da się obejść: proces stygnie między turami. Pierwsze pytanie
po dłuższej przerwie potrafi zająć ~4,5 s zamiast ~1 s. Dlatego pytania lecą do
Claude'a **w momencie wykrycia w transkrypcji**, a nie po kliknięciu —
odpowiedź ma czekać, zanim ktokolwiek na nią spojrzy.

Flaga `--bare` wygląda jak skrót (pomija hooki i wtyczki), ale pomija też
źródła ustawień razem z autoryzacją i zwraca `Not logged in` — nie da się jej
użyć.

### Zmierzony pełny łańcuch

8,8 s polskiej mowy z pytaniem w środku zdania, Apple M4, oba serwery ciepłe:

| etap | czas |
| --- | ---: |
| transkrypcja (whisper.cpp small) | 711 ms |
| wykrycie pytania | 1 ms |
| budowa promptu | 0 ms |
| Claude — pierwszy token | 1861 ms |
| **od końca mowy do pierwszego tokenu** | **2573 ms** |
| pełna odpowiedź | 4862 ms |

Drugie pytanie w tej samej sesji: 1700 ms do pierwszego tokenu, 3675 ms całość.

Rozgrzewka mostu (5,1 s) płacona jest raz, przy `npm run assistant`, zanim
zacznie się rozmowa.

Warto odnotować: ASR zniekształcił „RTO" na „to" i „backupów" na „bad skupów",
a Claude i tak odpowiedział poprawnie o RPO vs RTO — model rekonstruuje sens
z kontekstu. Dla gęstego słownictwa technicznego `large-v3-turbo` radzi sobie
lepiej niż `small`, kosztem ~1 s.

### Jak to jest spięte

```
transkrypcja -> wykrycie pytania -> service worker -> most HTTP -> ciepły CLI
                                         ^                              |
                                    nakładka  <----- strumień tokenów ---+
```

Trzy decyzje warte odnotowania:

- **Zapytanie wychodzi z service workera, nie z content scriptu.** `fetch`
  w content scripcie ma origin strony (`https://meet.google.com`), a most
  wpuszcza wyłącznie `chrome-extension://`. Strumień wraca do nakładki portem.
- **Nakładka żyje w Shadow DOM.** Wstrzykujemy się w cudzą stronę — bez
  izolacji jej CSS zniszczyłby nasz i odwrotnie.
- **Bez WebSocketów.** Wymagałyby zależności `ws` albo ręcznego ramkowania
  RFC 6455; strumieniowany `fetch` daje to samo przy zerze zależności.

### Wykrywanie pytań

Napisy z mowy nie mają interpunkcji, więc pytajnik to tylko jeden z sygnałów —
obok słów pytających i zwrotów typu „czy ktoś wie". Pytania techniczne
(„czy mnie słychać", „widzicie mój ekran") są odsiewane, bo asystent nie ma na
nie czego odpowiedzieć.

Dopasowanie idzie po tekście złożonym do ASCII: w mowie szyk jest swobodny
(„czy mnie słychać" vs „czy słychać mnie"), a `\b` w JS nie stawia granicy
wokół polskich liter — `\bsłychać\b` nie dopasowuje się do niczego.

Ocena idzie zdanie po zdaniu, a nie po frazach. Na prawdziwej rozmowie
kwalifikacyjnej (23 min, whisper small) dawne podejście, które liczyło słowo
pytające na początku dowolnej frazy, uznało za pytania 48 ze 158 wypowiedzi,
w tym „Podobało mi się, **jak** zrobiłeś”, „praca, **która** była” i „A **co**
dalej będzie, to nie wiadomo.”. Obecne reguły zostawiają 31 i każde z nich to
faktyczne pytanie:

- Słowo pytające liczy się tylko na początku zdania, po wypełniaczach („Okej,
  dobra, a jak…”) albo po wstępie („mam pytanie, czym…”, „powiedz mi, ile…”).
  Po zwykłej frazie to prawie zawsze zaimek względny albo spójnik.
- Kropka od whispera osłabia słowo pytające, a wielokropek oznacza urwaną myśl.
  Pełną wagę ma ono tylko z pytajnikiem albo w tekście bez interpunkcji
  (napisy Meet).
- Samo „…, tak?” albo „…, nie?” to prośba o potwierdzenie, nie pytanie do
  asystenta. Zostaje za to jako kontekst, gdy zaraz po nim pada właściwe
  pytanie.
- Do modelu idzie całe pytanie razem z serią pytań po nim („Ile to będzie lat?
  Rok? Dwa?”), bez wstępu i bez tego, co padło po nim.
- Halucynacje whispera na ciszy („Dziękuję za uwagę.”, „Dzięki za
  oglądanie!”) wycinamy już z transkryptu. W tamtej rozmowie pojawiały się
  co minutę.

### Bezpieczeństwo mostu

Most słucha wyłącznie na `127.0.0.1` i wpuszcza tylko originy
`chrome-extension://` — inaczej dowolna otwarta strona mogłaby zadawać pytania
Twojemu CLI. Dodatkowo `--token <sekret>` wymusza nagłówek `Authorization`.
Nie wystawiaj mostu na `0.0.0.0`.

Narzędzia są wyłączone (`--disallowed-tools`): asystent ma odpowiadać, a nie
czytać ani zmieniać pliki. Proces startuje w katalogu tymczasowym, żeby kontekst
Twojego projektu nie wyciekał do odpowiedzi na pytania z rozmowy.

## Instalacja

```bash
git clone <repo> && cd call-whisper
```

1. `chrome://extensions` → **Tryb dewelopera**
2. **Załaduj rozpakowane** → wskaż katalog `extension/`

Wymagany Chrome 133+ (starsze nie przyjmą `MediaStreamTrack` w Web Speech API).

### Tryb głosu wymaga dwóch rzeczy jednorazowo

**1. Model mowy.** Rozpoznawanie lokalne używa komponentu SODA — tego samego,
który stoi za „Napisami na żywo" w Chrome. Dopóki ich nie włączysz, model nie
jest pobrany i `SpeechRecognition.available({processLocally: true})` zwraca
`downloadable`, a start rozpoznawania kończy się błędem
`language-not-supported`. Wywołanie `install()` tego **nie** naprawia — potrafi
zwrócić `false` nawet przy poprawnym geście użytkownika.

Popup → ⚙ → **Pobierz model mowy (Napisy na żywo)** otwiera
`chrome://settings/captions`. Włącz Napisy na żywo i dodaj swój język. Model
schodzi w tle; rozszerzenie sprawdza to co 15 s i **samo przełącza się na
rozpoznawanie lokalne**, gdy będzie gotowy — bez restartu nagrywania.

**2. Mikrofon.** Popup → ⚙ → **Nadaj dostęp do mikrofonu**. Zgody nie da się
nadać z niewidocznego tła, stąd osobna strona. Bez niej tryb głosu nadal działa,
tylko na samym dźwięku karty.

### Groq Whisper

Popup → ⚙ → **Silnik: Groq Whisper**, potem wklej klucz z
`console.groq.com/keys`. Klucz siedzi w `chrome.storage.local` — czyli jest
dostępny dla każdego, kto ma dostęp do Twojego profilu Chrome.

Zanim uruchomisz to w przeglądarce, warto sprawdzić klucz i model z konsoli —
tym samym klientem, którego używa wtyczka:

```bash
cp .env.example .env      # wklej GROQ_API_KEY
node tools/transcribe.mjs nagranie.wav --lang pl --segments
```

### Awaryjnie: rozpoznawanie w chmurze Google

Jeśli lokalnego modelu nie da się pobrać, w ustawieniach jest przełącznik
**Zezwól na chmurę Google** — domyślnie wyłączony. Włączony sprawia, że
transkrypcja działa od razu, ale **audio opuszcza urządzenie** i trafia na
serwery Google. Popup pokazuje wtedy „chmura Google" przy nazwie sesji, żeby nie
dało się tego przeoczyć.

## Jak działa tryb napisów Meet

Google Meet ma własne napisy na żywo i sam wie, czyj strumień audio jest
aktywny. Czytamy je z DOM-u — bez modelu ASR, bez dotykania dźwięku.

Uwaga na słowo „diaryzacja": Meet **nie rozpoznaje po głosie**. Przypisuje
wypowiedź do uczestnika, którego strumień był aktywny. Tam, gdzie każdy siedzi
przy swoim laptopie, jest to dokładniejsze od jakiejkolwiek analizy akustycznej.
Pięć osób przy jednym mikrofonie w sali dostanie jednak jedną etykietę — i to
jest właśnie przypadek dla trybu głosu.

## Jak działa rozpoznawanie po głosie

Dwa niezależne strumienie informacji, wiązane w czasie:

**Co padło** — on-device Web Speech API (`processLocally: true`). Model mowy
dostarcza i aktualizuje Chrome jako pakiet językowy; my nie hostujemy wag i nie
wysyłamy audio na serwer. Rozpoznawanie karmimy `MediaStreamTrack`, więc działa
na dźwięku karty, nie tylko na mikrofonie. Wymaga pobranego modelu — patrz
[Instalacja](#tryb-głosu-wymaga-dwóch-rzeczy-jednorazowo).

**Kto mówi** — własna diaryzacja, bo na to nie ma żadnego API:

```
PCM 16 kHz -> VAD -> MFCC -> embedding wypowiedzi -> klastrowanie online
```

- **VAD** na energii ze statystyką minimum. Podłoga szumu to minimum z ostatnich
  3 s, nie średnia — dzięki temu stały wentylator nie jest mową, a długa
  wypowiedź nie ucina się w połowie.
- **MFCC** (26 filtrów mel, 12 współczynników cepstralnych bez `c0`). Odrzucenie
  `c0` sprawia, że cechy niosą barwę głosu, a nie głośność.
- **Embedding** = średnia + odchylenie MFCC z wypowiedzi, znormalizowane L2.
- **Klastrowanie online** po podobieństwie kosinusowym: powyżej progu to znany
  mówca, poniżej — nowy.

Dodatkowo rozdzielamy **źródła**, co daje darmowy i bezbłędny podział „ja" vs
„oni": mikrofon to Ty i osoby obok, dźwięk karty to zdalni uczestnicy. Diaryzacja
pracuje osobno wewnątrz każdego źródła.

### Dlaczego Groq poprawia nie tylko dokładność

Groq nie ma streamingu — to zwykły POST pliku. Wygląda na wadę, a wymusza
rozwiązanie lepsze od tego, co robi Web Speech.

Skoro audio trzeba pociąć, tniemy je **na granicach wypowiedzi wykrytych przez
VAD**, a nie co N sekund. Wtedy jedno żądanie = jedna zamknięta tura
diaryzatora, czyli chunk *z definicji* należy do jednego mówcy.

Przy Web Speech przypisanie osoby jest zgadywaniem: rozpoznawanie nie oddaje
znaczników czasu słów, więc pytamy diaryzator, kto dominował w oknie czasu
wyniku. Przy Groqu ten problem znika — mówca jest znany, zanim jeszcze
zapytamy o tekst. Do tego `verbose_json` dorzuca znaczniki czasu segmentów.

Praktyczne konsekwencje:

- Segment pojawia się w UI od razu jako `…` i wypełnia się, gdy wróci
  odpowiedź — inaczej interfejs wyglądałby na zawieszony.
- Wypowiedzi krótsze niż 600 ms są odsiewane: to zwykle kaszlnięcia, a Groq
  nalicza **minimum 10 s za żądanie** niezależnie od długości.
- Kolejka jest szeregowa (kolejność transkryptu musi się zgadzać) i przy
  zaległościach powyżej 12 żądań zaczyna gubić kawałki, zamiast rosnąć bez
  końca.

### Czego tryb głosu nie potrafi

Warto wiedzieć przed użyciem:

- Klastrowanie MFCC to podejście **sprzed ery sieci neuronowych**. Rozdziela
  wyraźnie różne głosy; podobne (np. dwaj mężczyźni o zbliżonej barwie) potrafi
  skleić w jednego mówcę. Model typu x-vector byłby lepszy, ale oznaczałby
  kilkadziesiąt MB wag i bundler.
- Etykiety są **anonimowe** („Rozmówca 2"), bo z samego głosu nie da się
  odczytać imienia.
- Wiązanie tekstu z mówcą jest **przybliżone**: Web Speech nie oddaje znaczników
  czasu słów, więc pytamy diaryzator, kto dominował w oknie czasu danego wyniku.
  Przy naprzemiennej rozmowie działa dobrze, przy mówieniu jednocześnie — gorzej.
- Jakość transkrypcji to jakość lokalnego modelu Chrome dla danego języka.

## Użycie

Ikona rozszerzenia otwiera popup:

- **przełącznik trybu** — napisy Meet / rozpoznawanie głosu
- **Start** / **Słuchaj tej karty** — nagrywanie
- **Kopiuj MD**, **Pobierz .md**, **.json** — eksport
- ⚙ — auto-start, format Markdown, język mowy, mikrofon

Licznik na ikonie pokazuje liczbę zarejestrowanych wypowiedzi; czerwona kropka
oznacza nasłuch audio.

### Z linii poleceń

Eksport `.json` przerenderuje ten sam rdzeń, którego używa rozszerzenie:

```bash
node tools/render.mjs sesja.json > notatka.md
node tools/render.mjs sesja.json --locale en --absolute --no-frontmatter
```

## Format wyjściowy

```markdown
---
title: "Standup zespołu"
source: google-meet
url: "https://meet.google.com/abc-defg-hij"
date: 2026-08-23
started: "2026-08-23 10:15:03"
duration: "00:42:11"
speakers: ["Anna Kowalska", "Jan Nowak"]
generator: call-whisper
---

# Standup zespołu

2026-08-23 10:15 · 42m 11s · Google Meet

## Uczestnicy

| Osoba | Wypowiedzi | Słowa | Udział |
| --- | ---: | ---: | ---: |
| Anna Kowalska | 24 | 812 | 61% |
| Jan Nowak | 17 | 518 | 39% |

## Transkrypt

**[00:00:04] Anna Kowalska**

Cześć wszystkim, zaczynamy standup.
```

## Architektura

```
extension/
├─ manifest.json
├─ background.js              service worker: trwałość sesji, eksport, tabCapture
├─ content/                   Meet: boot.js -> main.js (dynamiczny import ESM)
├─ offscreen/                 tryb audio: MediaStream + AudioWorklet + ASR
├─ permission/                jednorazowa zgoda na mikrofon
├─ popup/                     UI (design system HeroUI w czystym CSS)
└─ src/                       ← rdzeń, czysty ESM, bez API przeglądarki
   ├─ core/
   │  ├─ text.js              scalanie strumienia migawek (reconcile)
   │  ├─ transcript.js        TranscriptStore: segmenty, mówcy, finalizacja
   │  ├─ markdown.js          renderer Markdown (pl / en)
   │  ├─ session.js           metadane + serializacja
   │  ├─ settings.js          ustawienia
   │  └─ time.js              formatowanie czasu
   └─ adapters/
      ├─ meet/                dom.js (odczyt napisów) + index.js (obserwacja)
      └─ audio/
         ├─ fft.js            FFT radix-2
         ├─ features.js       MFCC: mel, DCT, preemfaza
         ├─ vad.js            VAD ze statystyką minimum
         ├─ diarizer.js       embedding + klastrowanie online
         ├─ framer.js         cięcie strumienia na ramki analizy
         ├─ asr.js            on-device Web Speech + auto-restart
         ├─ index.js          AudioAdapter: ASR + diaryzacja -> transkrypt
         ├─ ring.js           kołowy bufor audio (cięcie po czasie tury)
         ├─ wav.js            PCM -> WAV
         ├─ groq.js           klient Groq + kolejka z retry
         ├─ groq-adapter.js   tura diaryzatora = jedno żądanie
         ├─ whisper-local.js  klient lokalnego whisper.cpp
         └─ streaming-adapter.js  transkrypcja W TRAKCIE mówienia

asr/whisper.mjs                 ← launcher lokalnego whisper.cpp
assistant/                      ← most do lokalnego CLI (uruchamiany osobno)
├─ claude-process.mjs           ciepły proces claude, kolejka pytań
└─ server.mjs                   HTTP + strumień JSON-lines
```

Aplikacja natywna — te same warstwy, ten sam podział na czysty rdzeń i platformę:

```
macos/
├─ Package.swift                SwiftPM, zero zależności zewnętrznych
├─ tools/
│  ├─ bundle.sh                 składa .app + podpis (certyfikat, inaczej ad-hoc)
│  ├─ make-cert.sh              lokalny certyfikat, żeby zgody TCC przeżyły build
│  └─ gen-fixtures.mjs          wektory referencyjne z implementacji JS
└─ Sources/
   ├─ CallWhisperCore/          ← rdzeń: czysta logika, bez UI i bez AV
   │  ├─ Text.swift             reconcile / normalize / fold
   │  ├─ Time.swift             formatowanie czasu
   │  ├─ TranscriptStore.swift  segmenty, mówcy, finalizacja, pieczętowanie
   │  ├─ Markdown.swift         renderer (pl / en)
   │  ├─ Assistant.swift        wykrywanie pytań, prompt, stan odpowiedzi
   │  ├─ Vocabulary.swift       słownictwo whispera z pliku kontekstu
   │  ├─ DSP.swift              FFT (Accelerate), MFCC, VAD
   │  └─ Diarizer.swift         embedding, klastrowanie online, framer
   ├─ CallWhisperKit/           ← platforma
   │  ├─ AudioCapture.swift     ScreenCaptureKit (system) + AVAudioEngine (mik.)
   │  ├─ SpeechRecognizer.swift SpeechAnalyzer: ASR on-device + pobranie modelu
   │  ├─ SourcePipeline.swift   aktor: kolejka audio -> diaryzacja + ASR
   │  ├─ AssistantClient.swift  strumieniowe SSE, katalog modeli z pomiarami
   │  ├─ AppSettings.swift      UserDefaults + Keychain na klucz
   │  └─ Recorder.swift         spina wszystko, jedyny obiekt na głównym aktorze
   └─ CallWhisper/              ← UI (SwiftUI)
      ├─ main.swift             wejście: UI albo --probe
      ├─ MainView.swift         transkrypt + panel asystenta
      ├─ Overlay.swift          NSPanel nad rozmową, nie kradnie fokusu
      ├─ NotchIsland.swift      wyspa w notchu (Dynamic Island), --notch-demo
      └─ SettingsView.swift     ustawienia
```

Dwie decyzje warte odnotowania:

- **DSP nie chodzi na głównym aktorze.** Ramki lecą co 10 ms; MFCC i FFT nie
  mają czego szukać w wątku rysującym interfejs. `SourcePipeline` jest aktorem,
  a na główny wątek wychodzą dopiero gotowe fragmenty transkryptu.
- **Audio wchodzi kanałem szeregowym, nie przez `Task` na callbacku.** Zadania
  startują w kolejności dowolnej, a przestawione bloki próbek rozjeżdżają okno
  ramki i oś czasu diaryzatora względem ASR. `AsyncStream` z nieograniczonym
  buforem porządkuje je z powrotem — gubienie próbek nie wchodzi w grę, bo
  przesunęłoby licznik ramek względem znaczników czasu z rozpoznawania.

`src/` nie zna `chrome.*` ani `document`, więc te same pliki importują testy w
node i CLI. Content script ładuje je jako moduły ES (`boot.js` robi `import()`
na `chrome.runtime.getURL`) — **nie ma kroku build i nie ma zależności npm**,
łącznie z całym DSP i testami.

### Trzy problemy, które rozwiązuje rdzeń

**1. Strumień napisów to ciąg migawek, nie zdarzenia.** Meet i ASR aktualizują
ten sam blok tekstu w miejscu: tekst rośnie, bywa poprawiany, bywa przycinany od
początku. `reconcile()` sprowadza kolejne migawki do jednego zdania — wykrywa
wzrost, poprawkę in-place, przewijane okno i treść rozłączną. Ta sama funkcja
obsługuje wyniki interim z Web Speech.

**2. Wiszący blok nie może zdublować wypowiedzi.** Meet zostawia napisy widoczne
jeszcze długo po tym, jak ktoś skończy mówić. Bez pamięci domkniętych bloków
każdy kolejny odczyt tworzyłby nowy segment z tą samą treścią — w kółko.
`TranscriptStore` pamięta, co już zapisał, i wpuszcza wyłącznie realnie nową
treść.

**3. Meet mieli klasy CSS.** `meet/dom.js` traktuje znane `jsname` i klasy jako
*podpowiedzi*, a gdy ich zabraknie, rozpoznaje blok po strukturze: awatar +
krótka etykieta z nazwiskiem + dłuższy blok tekstu.

### Dodanie nowej platformy

Adapter musi tylko wypychać migawki do `TranscriptStore`:

```js
store.upsert({
  key,      // stabilny identyfikator bloku napisów / wyniku ASR
  speaker,  // nazwa mówcy albo null
  text,     // pełna aktualna treść
  at,       // timestamp
});
```

Reszta — scalanie, finalizacja po ciszy, sklejanie poszatkowanych wypowiedzi,
statystyki i Markdown — jest wspólna.

## Rozwój

```bash
npm test                      # 190 testów JS, node:test, zero zależności
npm run mac:test              # 20 testów Swift, w tym zgodność z JS
npm run mac:build             # macos/build/call-whisper.app
npm run mac:probe <model>     # sprawdzenie klucza i modelu bez UI
npm run mac:fixtures          # przegenerowanie wektorów referencyjnych z JS
npm run icons                 # regeneracja ikon PNG
node tools/transcribe.mjs f.wav   # sprawdzenie klucza Groq bez przeglądarki
npm run assistant             # most do Claude Code (tryb asystenta, wersja web)
npm run whisper               # lokalny whisper.cpp (najszybsza transkrypcja)
python3 -m http.server 8765   # potem: /tools/preview/index.html — podgląd popupu
```

**Zmieniasz rdzeń? Zmień go po obu stronach i przegeneruj fixtures.** Testy
Swifta porównują się z wynikami JS, więc rozbieżność wyjdzie od razu — ale
tylko jeśli `fixtures.json` jest aktualny.

DSP jest testowane liczbowo, nie „na oko": FFT porównana z naiwną DFT do 1e-9,
MFCC sprawdzone pod kątem niezmienniczości na głośność, diaryzacja puszczona
przez syntetyczne głosy o różnych formantach. Testy DOM działają na własnej
mikro-atrapie zamiast jsdom — stąd zero `devDependencies`.

## Gdy coś nie działa

**„Słuchaj tej karty" nie reaguje.** Popup pokazuje teraz konkretny powód
w czerwonym alercie, który nie znika sam — wcześniej komunikat był kasowany
przez odświeżanie stanu co sekundę i wyglądało to na martwy przycisk.
Najczęstsza przyczyna: dokument offscreen nie zdążył wystartować (rozszerzenie
czeka na niego do 5 s i mówi, jeśli się nie doczeka).

**Sprawdzenie backendów z popupu:** ⚙ → „Sprawdź" przy adresie whisper.cpp
albo przy moście asystenta. Odpowiada od razu, bez wchodzenia w konsolę.

**Konsola dokumentu offscreen:** `chrome://extensions` → call-whisper →
„Sprawdź widoki: offscreen.html". Tam lądują błędy przechwytywania audio,
których nie widać w popupie.

**Uwaga dla rozwijających:** `node --check` sprawdza wyłącznie składnię, więc
przepuszcza odwołanie do niezdefiniowanej nazwy — a dokument offscreen żyje na
`chrome.*` i nie da się go pokryć testami wprost. Dlatego decyzje trzymamy
w czystych modułach (`backend-plan.js`), a `test/modules.test.mjs` importuje
wszystko z `src/`, żeby wyłapać zepsute moduły. Pełną analizę zasięgu nazw
dałby dopiero linter — świadomie go nie dodajemy, bo repo ma zero zależności.

## Ograniczenia

- Tryb Meet wymaga włączonych napisów (rozszerzenie umie je włączyć samo).
- Tryb głosu wymaga Chrome 133+ **oraz pobranego modelu SODA** — który schodzi
  dopiero po włączeniu Napisów na żywo w Chrome. Bez tego rozpoznawanie zwraca
  `language-not-supported`; popup mówi wprost, co zrobić.
- Dostępność modelu lokalnego bywa różna zależnie od systemu i wersji Chrome.
  Stan sprawdzisz w konsoli dowolnej strony:
  `await SpeechRecognition.available({ langs: ['pl-PL'], processLocally: true })`
- `tabCapture` wycisza kartę, więc dźwięk wracamy na głośniki przez Web Audio —
  przy zmianie urządzenia wyjściowego w trakcie rozmowy trzeba zrestartować
  nasłuch.
- Etykiety mówców w trybie głosu są anonimowe i mogą się mylić przy podobnych
  barwach głosu (patrz „Czego tryb głosu nie potrafi").
- Klucz Groqa trzymany jest w `chrome.storage.local`, bez szyfrowania — tak samo
  jak wszystkie sekrety rozszerzeń Chrome. Nie wkładaj tam klucza produkcyjnego
  o szerokich uprawnieniach.
- `.env` obsługują wyłącznie narzędzia z `tools/`; rozszerzenie nie ma dostępu
  do dysku i czyta klucz z własnych ustawień.

Aplikacja natywna:

- Wymaga **macOS 26** — `SpeechAnalyzer` i `SpeechTranscriber` pojawiły się
  dopiero tam. Na starszych systemach zostaje rozszerzenie.
- **Zgoda na nagrywanie ekranu jest obowiązkowa**, choć obrazu nie dotykamy:
  ScreenCaptureKit tak właśnie wydaje dźwięk systemu. Konfiguracja strumienia
  bierze najmniejszą dopuszczalną klatkę (2×2 px, raz na sekundę), ale samej
  zgody nie da się ominąć.
- Podpis wymaga **certyfikatu** (deweloperskiego albo lokalnego z
  `make-cert.sh`), żeby zgody TCC przeżywały przebudowy, patrz „Podpis:
  dlaczego ad-hoc nie wystarczy". Do rozdania innym trzeba Developer ID
  i notaryzacji.
- **Klucz API w Keychainie jest czytelny dla każdego procesu na Twoim koncie.**
  To świadoma decyzja, opisana niżej — nie przypadek.
- **Domyślny model podpowiedzi jest darmowy, a więc wolny** (~5,7 s do
  pierwszego tokenu) i bywa odrzucany błędem 429. Patrz „Podpowiedzi: który
  model i dlaczego".
- **Polski wymaga whisper.cpp** (`brew install whisper-cpp` + model). Silnik
  Apple obsługuje 30 języków i nie ma wśród nich polskiego.
- Whisper na ciszy potrafi wyprodukować zdanie, którego nikt nie powiedział.
  Tury krótsze niż 600 ms są odrzucane bez pytania modelu, ale to nie usuwa
  problemu w całości.
- Mikrofon jest **domyślnie wyłączony** — nagrywany jest sam dźwięk systemu.
  Włączony i puszczony na głośnikach łapie echo, więc każda wypowiedź trafia
  do transkryptu dwa razy: raz jako „Rozmówcy", raz jako „Ty". Na słuchawkach
  problem znika, więc włącz go wtedy, gdy Twój własny głos ma być w notatce.
- Etykiety mówców są anonimowe tak samo jak w trybie głosu w przeglądarce —
  z samego głosu nie da się odczytać imienia. Rozdzielenie mikrofonu od dźwięku
  systemu daje jednak pewne „Ty" vs „Rozmówcy", bez zgadywania.

## Zgody

Nagrywanie i transkrybowanie rozmowy bywa objęte prawem lokalnym i regulaminem
organizacji. Poinformuj pozostałych uczestników.
<!-- bump: 1c3e9b2 -->
