# opencode-limit-alert

Plugin do [OpenCode v2](https://opencode.ai) dla macOS. Gdy agent stanie, bo skończył się limit (rate limit / 429 / quota), padnie z błędem albo skończy zadanie, plugin:

1. pokazuje banner w prawym górnym rogu z listą zadań, które stanęły,
2. czyta na głos: *„Skończył się limit. Zadanie: <tytuł sesji>.”*

Klik w zadanie na liście przełącza na jego kartę w **herdr**, **Orca** albo **Ghostty**.

```
┌──────────────────────────────────────────┐
│ >_ OPENCODE · 3 ZADANIA            08:45 │
│ ✓  Raycast z OmniRoute i MCP          ×  │
│    Zadanie skończone · 08:45 · herdr     │
│ ⚠  Aktualizacje na GitHubie           ×  │
│    Zadanie stanęło · 08:45 · Orca        │
│ ⌛ Lekka aplikacja notatek Raycast     ×  │
│    Skończył się limit · 08:45 · Ghostty  │
│ [         Wyczyść wszystko          ]    │
└──────────────────────────────────────────┘
```

Głos: [ElevenLabs](https://elevenlabs.io) (jeśli podasz klucz). Gdy ElevenLabs nie działa (brak klucza, brak sieci, brak kredytów, błąd API), czyta darmowy systemowy głos macOS (`say`, domyślnie polska Zosia).

*English: OpenCode v2 plugin that shows a top-right banner listing stalled sessions (click to jump to the tab in herdr, Orca or Ghostty) and speaks the session title (ElevenLabs TTS with a free `say` fallback) when a session hits a rate limit, fails, or finishes.*

## Instalacja

```sh
git clone https://github.com/hubsoapp-beep/opencode-limit-alert.git
cd opencode-limit-alert
./install.sh
```

Skrypt kopiuje `limit-alert.js` do `~/.config/opencode/plugins/`, banner `alerts.py` do `~/bin/opencode-alerts/` i tworzy `~/.config/opencode/limit-alert.json` z przykładu. Potem zrestartuj opencode. Jeśli działa usługa w tle (`opencode serve --service`), zrestartuj też ją.

## Konfiguracja

`~/.config/opencode/limit-alert.json`:

| pole | domyślnie | opis |
|---|---|---|
| `elevenlabsApiKey` | `""` | klucz ElevenLabs; można też użyć env `ELEVENLABS_API_KEY`. Pusty = tylko głos systemowy |
| `voiceId` | `EXAVITQu4vr4xnSDxMaL` (Sarah) | głos ElevenLabs. Na planie Free działają tylko głosy *premade*; głosy z biblioteki zwracają 402 |
| `modelId` | `eleven_flash_v2_5` | model TTS (szybki, tani, obsługuje polski) |
| `systemVoice` | `Zosia` | głos `say` do fallbacku (`say -v '?'` pokazuje listę) |
| `bannerApp` | `~/bin/opencode-alerts/alerts.py` | banner z listą; brak pliku = zwykłe powiadomienie macOS |
| `announceDone` | `true` | czytaj też „Zadanie skończone” |
| `toastHoldSeconds` | `4` | ile sekund baner trzyma przeczytany alert, zanim pokaże następny |
| `toastNoVoiceSeconds` | `7` | to samo, gdy głos jest wyłączony |
| `debug` | `false` | loguj eventy sesji do `$TMPDIR/limit-alert.log` |

Klucz trzymaj tylko w tym pliku lokalnie. Plik jest w `.gitignore`.

## Co wyzwala alert

| event OpenCode | alert |
|---|---|
| hook `retry` z błędem 429 / „rate limit” | Skończył się limit |
| `session.execution.failed` z treścią o limicie | Skończył się limit |
| `session.execution.failed` (inny błąd) | Zadanie stanęło |
| `session.execution.succeeded` | Zadanie skończone (jeśli `announceDone`) |

Ten sam alert dla tej samej sesji odzywa się najwyżej raz na 60 s, także gdy plugin działa w kilku procesach opencode naraz.

## Kolejka powiadomień

Gdy w krótkim czasie pojawi się kilka alertów, **nie wyskakują naraz i nie mówią jednocześnie**:

- baner pokazuje **jeden alert na raz** (`1 / 3`, `2 / 3`…), a po przeczytaniu i krótkiej pauzie przechodzi do następnego,
- głos ma jedną wspólną kolejkę — następne zdanie startuje dopiero po zakończeniu poprzedniego,
- natywne powiadomienie macOS też leci w rytmie kolejki, więc nie zasypuje ekranu.
- Długość pauzy ustawisz w Ustawieniach → **Kolejka banera** (`toastHoldSeconds`, `toastNoVoiceSeconds`).

### Sterowanie klawiaturą

Gdy baner jest widoczny:

| klawisz | działanie |
|---|---|
| **← / →** | wybór akcji (Odrzuć / Przejdź) |
| **Tab** / **Shift+Tab** | przełączenie między przyciskami |
| **1** / **2** | od razu Odrzuć / Przejdź |
| **↵** / **Space** | wykonaj wybraną akcję |
| **Esc** | odrzuć bieżący alert |
| **⌥⌘L** | nadaj banerowi fokus klawiatury (bez przełączania aplikacji) |

Klik w baner też nadaje fokus. Bez fokusu baner nie przechwytuje klawiszy z terminala.

## Banner z listą (alerts.py)

`alerts.py` to mały program w Pythonie z PyObjC (oba są w macOS, nic nie trzeba instalować). Plugin zapisuje każde zdarzenie jako plik w `~/.opencode-alerts/` (jeden na sesję) i uruchamia `alerts.py show`. Banner odświeża listę co sekundę i znika, gdy lista jest pusta. Nie zabiera fokusu z klawiatury. To tryb awaryjny — gdy działa `LimitAlert.app`, to ona pokazuje kolejkę opisana wyżej.

- klik w wiersz albo **Przejdź**: przełącza na kartę zadania i zdejmuje je z listy,
- **×** / **Odrzuć**: zdejmuje zadanie bez przełączania,
- **Wyczyść wszystko**: czyści listę,
- gdy zadanie ruszy dalej (`session.execution.started`), samo znika z listy.

Jak banner znajduje kartę:

| terminal | dopasowanie | przełączenie |
|---|---|---|
| herdr | `herdr pane list`: ID sesji, potem tytuł | `herdr workspace focus` + `herdr tab focus` + okno Ghostty z herdr |
| Orca | `orca terminal list`: tytuł `OC \| …` | `orca terminal switch --terminal <handle>` |
| Ghostty | menu Window: tytuł `OC \| …` (także ucięty `…`) | klik w pozycję menu |

Przełączanie w Ghostty klika w menu przez System Events. Za pierwszym razem macOS poprosi o zgodę na **Dostępność** / **Automatyzację**. Zezwól w Ustawieniach systemowych → Prywatność i ochrona.

Z wiersza poleceń:

```sh
~/bin/opencode-alerts/alerts.py add "Testowe zadanie" --kind limit   # dodaj testowy alert
~/bin/opencode-alerts/alerts.py show                                 # pokaż banner
~/bin/opencode-alerts/alerts.py list                                 # co wisi
~/bin/opencode-alerts/alerts.py jump "Tytuł sesji"                   # przełącz na kartę
~/bin/opencode-alerts/alerts.py clear                                # wyczyść
tail -f /tmp/opencode-alerts.log
```

## Odinstalowanie

```sh
./uninstall.sh
```

## Testy

```sh
python3 test_alerts.py     # dopasowanie kart i kolejka
```

## Test bez opencode

```sh
node test/fake-event.mjs
```

Wysyła udawany event „Rate limit exceeded”. Powinien pojawić się banner i głos.

## Wymagania

- macOS (`osascript`, `afplay`, `say`, systemowy `/usr/bin/python3` z PyObjC)
- OpenCode v2 (plugin API `setup(ctx)`)

## Licencja

MIT

## Claude Code i Codex

Od tej wersji `install.sh` instaluje też hooki dla Claude Code i Codex:

- **Claude Code** — dodaje hook `StopFailure` (oraz `SessionEnd`) do `~/.claude/settings.json`. Hook wywołuje `agent-hook.py claude-code`, który czyta payload, rozpoznaje limit (429 / "rate limit" / quota) i pokazuje banner + czyta tytuł (ElevenLabs / `say`).
- **Codex** — opakowuje istniejący `~/.codex/herdr-agent-state.sh` wrapperem (zachowuje zaufanie hooków Codexa) i wywołuje `agent-hook.py codex`. Alert odpala się, gdy `last_assistant_message` zawiera słowa o limicie.

Tytuł alertu to nazwa katalogu projektu (`cwd`), np. „Claude Code · myproject”.

## Aplikacja menu bar (LimitAlert.app)

`install.sh` (gdy jest `swift`) buduje `~/Applications/LimitAlert.app` — aplikację w pasku menu, która:
- pokazuje alerty **jeden po drugim** (wspólna kolejka banera i głosu — nic się nie nakłada),
- pozwala sterować banerem z klawiatury: **←/→**, **Tab**, **1/2**, **↵**, **Esc**; fokus włącza klik lub **⌥⌘L**,
- pokazuje listę alertów i pozwala przejść/odrzucić/wyczyścić,
- ma okno ustawień (klucz ElevenLabs, głosy per agent, cicha godzina, routing, webhook Slack/Telegram, natywne powiadomienia Apple, czas trzymania banera),
- czyta historię alertów,
- wysyła natywne powiadomienia macOS.

Uruchomienie: `open ~/Applications/LimitAlert.app`. Aplikacja startuje przy logowaniu (ustaw w Ustawieniach systemowych → Ogólne → Elementy logowania), jeśli dodasz ją ręcznie.

Gdy aplikacja działa, przejmuje baner i głos (z ustawieniami per agent, cichą godziną i routingiem). `alerts.py` i plugin JS zapisują wtedy tylko alert do kolejki — nie otwierają drugiego bannera ani nie czytają go ponownie. Po zamknięciu aplikacji wraca samodzielny banner Python (z blokadą głosu, więc równoległe procesy też się nie nakładają).

Jeszcze nie zaimplementowane: auto-aktualizacje (Sparkle), pełny status uprawnień Dostępności z przyciskiem naprawy.
