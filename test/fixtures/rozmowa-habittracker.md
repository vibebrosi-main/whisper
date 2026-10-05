# Skrypt testowy: rozmowa o projekcie HabitTracker

Materiał do wygenerowania w ElevenLabs i puszczenia przez `call-whisper`
z **włączonym kontekstem projektu**. Sprawdza to, czego poprzedni skrypt nie
sprawdzał: czy asystent odpowiada z wiedzy o repozytorium, czy zgaduje.

**Jak użyć:**

1. Ustawienia → Ogólne → Kontekst projektu wskazuje
   `~/Library/Application Support/call-whisper/project-context.md`.
2. Wklej do ElevenLabs `rozmowa-habittracker-elevenlabs.txt` (ma wstawione pauzy).
3. Odtwórz przy włączonym nasłuchu i porównaj ze ściągą niżej.

Długość: ~1,3 minuty mowy, 12 pytań.

Kształt rozmowy to przegląd projektu, na przykład rozmowa rekrutacyjna
o portfolio albo code review.

---

## Ściąga: czego oczekiwać

### Ma zostać odsiane

| wypowiedź | dlaczego |
| --- | --- |
| „Cześć, słychać mnie dobrze?" | small-talk |
| „Halo, halo." | za krótkie |
| „To zaczynajmy. Chciałbym dzisiaj przejść…" | wzorzec „to zaczynajmy" |
| „Aha." | krótsze niż 600 ms, odrzucane przed whisperem |
| „Dzięki, to wszystko z mojej strony." | brak sygnałów pytania |

### Pytania, na które odpowiedź jest **tylko w kodzie**

To jest właściwy test kontekstu. Bez niego model nie ma skąd znać tych liczb.

| pytanie | poprawna odpowiedź |
| --- | --- |
| Jak reprezentujecie wykonanie nawyku w bazie? | Przez **istnienie wiersza** w `habit_logs`, nie przez flagę. Odznaczenie usuwa wiersz. |
| W której wersji jest schemat i co zmieniała migracja? | Wersja **2**. `MIGRATION_1_2` dodaje `reminder_enabled` i `reminder_time` przez `ALTER TABLE`. |
| Ile wynosi domyślna godzina przypomnienia i w czym jest trzymana? | **480**, czyli 8:00. Minuty od północy, `Int`. |
| Jak działa częstotliwość dla konkretnych dni? | Bitmaska w `frequencyValue`: pon=1, wt=2, … ndz=64. Sprawdza `isDueOnDay`. |
| Od której wersji Androida prosicie o uprawnienie? | **API 33** (Tiramisu), `POST_NOTIFICATIONS`. |
| Co z przypomnieniami po restarcie telefonu? | `BootReceiver` na `ACTION_BOOT_COMPLETED` odtwarza alarmy, bo `AlarmManager` ich nie przechowuje. |
| Jaki jest minimalny SDK? | **26**. |

### Pytanie kontrolne: czy model podąża za README, czy za kodem

> **Czekaj, czyli swipe nie usuwa nawyku? To gdzie jest usuwanie?**

Poprawnie: swipe oznacza wykonanie (w prawo) lub jego brak (w lewo), kafelek
wraca na miejsce, bo `confirmValueChange` zawsze zwraca `false`. Usuwanie jest
w `ManageHabitsScreen`, pod ikoną kosza, **bez potwierdzenia**.

Jeśli usłyszysz „swipe usuwa nawyk", kontekst nie dotarł.

### Pytanie na uczciwość

> **Ile testów jednostkowych ma ten projekt i jakie jest pokrycie kodu?**

Projekt **nie ma testów**, a kontekst o nich nie wspomina. Poprawna odpowiedź to
przyznanie, że tego nie wie, a nie wymyślona liczba. Prompt systemowy mówi wprost:
„Jeśli pytanie dotyczy liczb lub faktów, których nie znasz na pewno, powiedz to
jednym zdaniem".

To jedyne pytanie w skrypcie, na które **nie ma** dobrej odpowiedzi merytorycznej.

### Pytanie z przecinkami

> **Czy ktoś wie, co się dzieje ze statusem wykonania, gdy aplikacja stoi w tle
> przez całą noc i mija północ?**

Sprawdza wycinanie pytania: pytajnik pada dopiero w trzeciej frazie, więc do
modelu musi trafić całość, a nie ogryzek „co się dzieje ze statusem wykonania".
Poprawna odpowiedź: `todayFlow` emituje datę co 60 s i przez `flatMapLatest`
przełącza strumień wykonanych, więc status resetuje się sam po północy.

### Pytanie bez rozstrzygnięcia w kodzie

> **Dlaczego użyliście KSP zamiast kapta?**

Kontekst mówi, że Room idzie przez KSP, ale nie podaje uzasadnienia. Dobra
odpowiedź poda ogólny powód (KSP jest szybszy i to kierunek rozwoju Kotlina),
najlepiej zaznaczając, że to nie wynika wprost z repozytorium.

---

## Wskazówki do generowania

- **Jeden głos wystarczy** (diaryzacja domyślnie wyłączona).
- **Nie usuwaj znaczników `<break>`.** Bez pauz VAD nie ma na czym domknąć
  wypowiedzi i całość skleja się w jeden blok, a pytania gubią się w środku.
- Odtwarzaj na słuchawkach albo zostaw mikrofon wyłączony.
