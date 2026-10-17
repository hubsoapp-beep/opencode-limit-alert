# opencode-limit-alert

Plugin do [OpenCode v2](https://opencode.ai) dla macOS. Gdy agent stanie, bo skończył się limit (rate limit / 429 / quota), padnie z błędem albo skończy zadanie, plugin:

1. pokazuje powiadomienie macOS z nazwą sesji i treścią błędu,
2. czyta na głos: *„Skończył się limit. Zadanie: <tytuł sesji>.”*

Głos: [ElevenLabs](https://elevenlabs.io) (jeśli podasz klucz). Gdy ElevenLabs nie działa (brak klucza, brak sieci, brak kredytów, błąd API), czyta darmowy systemowy głos macOS (`say`, domyślnie polska Zosia).

*English: OpenCode v2 plugin that shows a macOS notification and speaks the session title (ElevenLabs TTS with a free `say` fallback) when a session hits a rate limit, fails, or finishes.*

## Instalacja

```sh
git clone https://github.com/hubsoapp-beep/opencode-limit-alert.git
cd opencode-limit-alert
./install.sh
```

Skrypt kopiuje `limit-alert.js` do `~/.config/opencode/plugins/` i tworzy `~/.config/opencode/limit-alert.json` z przykładu. Potem zrestartuj opencode. Jeśli działa usługa w tle (`opencode serve --service`), zrestartuj też ją.

## Konfiguracja

`~/.config/opencode/limit-alert.json`:

| pole | domyślnie | opis |
|---|---|---|
| `elevenlabsApiKey` | `""` | klucz ElevenLabs; można też użyć env `ELEVENLABS_API_KEY`. Pusty = tylko głos systemowy |
| `voiceId` | `EXAVITQu4vr4xnSDxMaL` (Sarah) | głos ElevenLabs. Na planie Free działają tylko głosy *premade*; głosy z biblioteki zwracają 402 |
| `modelId` | `eleven_flash_v2_5` | model TTS (szybki, tani, obsługuje polski) |
| `systemVoice` | `Zosia` | głos `say` do fallbacku (`say -v '?'` pokazuje listę) |
| `announceDone` | `true` | czytaj też „Zadanie skończone” |
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

## Test bez opencode

```sh
node test/fake-event.mjs
```

Wysyła udawany event „Rate limit exceeded”. Powinno pojawić się powiadomienie i głos.

## Wymagania

- macOS (`osascript`, `afplay`, `say`)
- OpenCode v2 (plugin API `setup(ctx)`)

## Licencja

MIT
