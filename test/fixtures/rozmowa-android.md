# Skrypt testowy: rozmowa o Androidzie i Kotlinie

Materiał do wygenerowania w ElevenLabs i puszczenia przez `call-whisper`.
Nie jest to losowy tekst — każda sekcja sprawdza inną część łańcucha.

**Jak użyć:** wklej do ElevenLabs zawartość `rozmowa-android-elevenlabs.txt`
— to ten sam tekst z wstawionymi pauzami, które są tu **konieczne** (patrz
„Wskazówki" na końcu). Wersja bez znaczników leży w `rozmowa-android.txt` (jeden głos wystarczy —
przy wyłączonej diaryzacji wszystko i tak trafia jako „Rozmówcy"), wygeneruj,
odtwórz przy włączonym nasłuchu. Potem porównaj wynik ze „Ściągą" niżej.

Długość: ~3 minuty mowy.

---

## Do wklejenia

> Cześć wszystkim. Słychać mnie dobrze?
>
> Halo, halo.
>
> To zaczynajmy. Dzisiaj chciałem omówić migrację naszego modułu płatności z widoków XML na Jetpack Compose. Przepisaliśmy już ekran koszyka i ekran podsumowania zamówienia. Zostały nam dwa ekrany formularza i lista transakcji, która jest najbardziej złożona, bo ma paginację, filtrowanie i pull to refresh.
>
> Jaka jest różnica między StateFlow a SharedFlow?
>
> StateFlow zawsze trzyma aktualną wartość i emituje ją nowym subskrybentom natychmiast. SharedFlow nie ma wartości początkowej i można mu skonfigurować bufor replay. W praktyce StateFlow do stanu ekranu, SharedFlow do zdarzeń jednorazowych, takich jak nawigacja albo pokazanie snackbara.
>
> Wracając do tej listy transakcji, mam pytanie, czy LazyColumn recyklinguje elementy tak samo jak RecyclerView?
>
> Nie do końca tak samo, ale efekt jest podobny. LazyColumn tworzy kompozycje tylko dla widocznych elementów i porzuca te, które wyjechały poza ekran. Nie ma tam puli widoków do ponownego użycia, bo Compose nie ma widoków w tym sensie.
>
> Ile wynosi domyślny rozmiar puli wątków w Dispatchers punkt IO?
>
> Domyślnie sześćdziesiąt cztery wątki, albo tyle, ile jest rdzeni procesora, jeżeli rdzeni jest więcej. To jest limit współdzielony z Dispatchers punkt Default.
>
> Dobra. Teraz o wydajności. Zmierzyliśmy czas startu aplikacji na urządzeniu testowym i wychodzi nam osiemset milisekund do pierwszej klatki na Pixelu siódmym, a na budżetowym Samsungu z Androidem trzynaście prawie dwie i pół sekundy. Dodaliśmy Baseline Profile i to zbiło czas na tym słabszym urządzeniu do tysiąca sześciuset milisekund. Reszta narzutu siedzi w inicjalizacji Hilta i w migracjach bazy Room, które odpalamy synchronicznie na starcie, co jest błędem i trzeba to przenieść w tło.
>
> Czy ktoś wie, jak dokładnie działa remember w Compose?
>
> Remember zapamiętuje wartość w slocie kompozycji i zwraca ją przy kolejnych rekompozycjach, dopóki klucze się nie zmienią. Przy zmianie konfiguracji to nie wystarczy, wtedy potrzebny jest rememberSaveable, który zapisuje stan do Bundle.
>
> Od której wersji API dostępny jest Predictive Back?
>
> Aha.
>
> Jeszcze jedno. Czy migrujemy od razu na Kotlin Multiplatform, czy zostajemy przy czystym Androidzie?
>
> A jak to wpłynie na czas budowania w Gradle?
>
> I ostatnie pytanie, co robimy z ProGuardem i R8, bo mamy tam ręcznie pisane reguły, których nikt już nie rozumie?
>
> To tyle na dzisiaj. Dzięki i do zobaczenia jutro.

---

## Ściąga: co ma się stać

### Powinno zostać **odsiane** (nie generuje podpowiedzi)

| wypowiedź | dlaczego |
| --- | --- |
| „Słychać mnie dobrze?" | pytanie techniczno-organizacyjne, wzorzec `slychac` |
| „Halo, halo." | wzorzec `halo+` |
| „Aha." | krótsze niż 600 ms — odrzucane przed wysłaniem do whispera |
| „To tyle na dzisiaj…" | brak sygnałów pytania |

### Powinno **wywołać podpowiedź**

| wypowiedź | co testuje |
| --- | --- |
| „Jaka jest różnica między StateFlow a SharedFlow?" | słowo pytające na początku + pytajnik |
| „Wracając do tej listy transakcji, **mam pytanie**, czy LazyColumn…" | pytanie w środku wypowiedzi — do modelu ma pójść tylko część od „mam pytanie", bez dygresji |
| „Ile wynosi domyślny rozmiar puli wątków…" | słowo pytające bez pytajnika (mowa go nie daje) |
| „**Czy ktoś wie**, jak dokładnie działa remember…" | zwrot pytający |
| „Od której wersji API dostępny jest Predictive Back?" | pytanie o konkretną liczbę |

### Trzy pytania pod rząd na końcu

„Czy migrujemy na KMP", „A jak to wpłynie na czas budowania", „co robimy
z ProGuardem" — celowo bez przerw na odpowiedź.

**Oczekiwane:** odpowiedź na **jedno**, a nie kolejka trzech. Nowsze pytanie
wypiera starsze, a pytania starsze niż 20 s są porzucane. Jeśli zobaczysz trzy
karty odpowiedzi wypełniające się po kolei przez pół minuty — ograniczenie
kolejki nie działa.

### Długi monolog o wydajności

~35 sekund bez przerwy. **Oczekiwane:** tekst pojawia się w trakcie mówienia
i narasta, a po domknięciu wypowiedzi podmienia się na pełną wersję. Jeśli
zostanie tylko pierwszy fragment — wróciła regresja z domykaniem wypowiedzi.

### Pytania bez pytajnika

ASR nie zawsze oddaje pytajnik, a wtedy pytanie musi obronić się samym szykiem.
Sprawdzone na tym skrypcie: **8 z 8 pytań przechodzi bez pytajnika**.

Dwa z nich nie przechodziły, dopóki nie poprawiłem detektora przy pisaniu tego
skryptu:

| pytanie | dlaczego przepadało |
| --- | --- |
| „**Od której** wersji API dostępny jest Predictive Back" | słowo pytające stało na drugiej pozycji, za przyimkiem |
| „**A jak** to wpłynie na czas budowania w Gradle" | jw., za wtrąceniem „a" |

Detektor dopuszcza teraz jedno słówko przed słowem pytającym (`a`, `no`, `to`,
`od`, `w`, `na`…) i zna formy odmienione (`której`, `jakiego`, `ilu`).
Kontrola na zdaniach, które pytaniami **nie są** — „A potem wrócimy do listy
transakcji", „No i tyle w tym temacie" — nadal je odsiewa.

### Słownictwo do oceny jakości ASR

Te terminy whisper przekręca najchętniej — po nich najłatwiej ocenić, czy
`initial_prompt` z kontekstem działa:

`Jetpack Compose` · `StateFlow` · `SharedFlow` · `LazyColumn` · `RecyclerView`
`Dispatchers.IO` · `Baseline Profile` · `Hilt` · `Room` · `rememberSaveable`
`Predictive Back` · `Kotlin Multiplatform` · `Gradle` · `ProGuard` · `R8`

Charakterystyczne: **pierwsze wystąpienie bywa przekręcone, kolejne poprawne**
— bo termin trafił już do kontekstu podawanego whisperowi jako `initial_prompt`.
To jest właśnie ten mechanizm, który zbił błędy z 26,7 % na 13,3 %.

### Liczby do sprawdzenia

„osiemset milisekund", „Pixelu siódmym", „Androidem trzynaście", „dwie i pół
sekundy", „tysiąca sześciuset", „sześćdziesiąt cztery" — liczby wypowiedziane
słownie są klasycznym miejscem błędów.

---

## Wskazówki do generowania

- **Jeden głos wystarczy.** Diaryzacja jest domyślnie wyłączona, więc wszystko
  i tak trafi jako „Rozmówcy". Dialog dwoma głosami niczego tu nie zmieni.
- **Pauzy między akapitami są konieczne**, nie kosmetyczne. VAD domyka na nich
  wypowiedzi; bez nich całość skleja się w jeden blok. Zmierzone na nagraniu
  bez pauz: jeden segment na **1 minutę 43 sekundy**, w środku pytanie sklejone
  z odpowiedzią, prompt na setki znaków i podpowiedź po 9 s zamiast 1,5 s.

  Użyj gotowego `rozmowa-android-elevenlabs.txt` — ma wstawione
  `<break time="1.2s" />` po każdym akapicie.

  Aplikacja broni się przed tym twardym limitem 25 s na wypowiedź (tnie
  w najbliższej przerwie), ale cięcie w mowie ciągłej i tak wypadnie
  w przypadkowym miejscu — potrafi rozdzielić pytanie od jego początku.
- **Nie przyspieszaj.** Tempo szybsze niż naturalne psuje ASR i test przestaje
  mierzyć to, co powinien.
- **Odtwarzaj na słuchawkach albo wyłącz mikrofon** w ustawieniach (i tak jest
  domyślnie wyłączony) — inaczej mikrofon złapie echo z głośników.
