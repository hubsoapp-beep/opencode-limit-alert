// limit-alert — OpenCode v2 plugin.
// Gdy sesja stanie na limicie (429 / "rate limit") albo padnie z błędem, albo
// skończy zadanie: pokazuje powiadomienie macOS i czyta na głos tytuł sesji.
// Głos: ElevenLabs (jeśli jest klucz). Gdy ElevenLabs nie działa (brak klucza,
// brak sieci, 401/402/429, timeout) — darmowy systemowy `say` (Zosia).
//
// Konfiguracja: ~/.config/opencode/limit-alert.json (patrz limit-alert.example.json)
// {
//   "elevenlabsApiKey": "sk_...",          // albo env ELEVENLABS_API_KEY
//   "voiceId": "EXAVITQu4vr4xnSDxMaL",     // głos "premade" działa na planie Free
//   "modelId": "eleven_flash_v2_5",
//   "systemVoice": "Zosia",                // głos `say` do fallbacku
//   "announceDone": true,                  // czytaj też "zadanie skończone"
//   "debug": false                         // loguj eventy do $TMPDIR/limit-alert.log
// }

import { execFile } from "node:child_process"
import { appendFileSync, mkdirSync, openSync, closeSync, readFileSync, statSync, unlinkSync, writeFileSync } from "node:fs"
import { homedir, tmpdir } from "node:os"
import { join } from "node:path"

const CONFIG_PATH = join(homedir(), ".config/opencode/limit-alert.json")
const LOG_PATH = join(tmpdir(), "limit-alert.log")
const LOCK_DIR = join(tmpdir(), "limit-alert-locks")
const DEDUPE_MS = 60_000

function loadConfig() {
  let file = {}
  try {
    file = JSON.parse(readFileSync(CONFIG_PATH, "utf8"))
  } catch {
    // brak pliku = domyślne
  }
  return {
    apiKey: file.elevenlabsApiKey || process.env.ELEVENLABS_API_KEY || "",
    voiceId: file.voiceId || "EXAVITQu4vr4xnSDxMaL",
    modelId: file.modelId || "eleven_flash_v2_5",
    systemVoice: file.systemVoice || "Zosia",
    announceDone: file.announceDone !== false,
    debug: file.debug === true,
  }
}

const config = loadConfig()

// Strumieniowe eventy (delty, tool, step) zalałyby log.
const NOISY = /\.(delta|started|ended|streamed|progress|called|success|enqueued|delivered)$|usage|instructions/

function log(...args) {
  if (!config.debug) return
  try {
    const line = args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" ")
    appendFileSync(LOG_PATH, `${new Date().toISOString()} ${line.slice(0, 1000)}\n`)
  } catch {}
}

const run = (cmd, args) =>
  new Promise((resolve) => execFile(cmd, args, { timeout: 60_000 }, (err) => resolve(!err)))

// AppleScript string literal escape
const esc = (s) => String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"')

function notify(title, body) {
  return run("/usr/bin/osascript", [
    "-e",
    `display notification "${esc(body)}" with title "${esc(title)}" sound name "Basso"`,
  ])
}

async function speakElevenLabs(text) {
  const res = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${config.voiceId}?output_format=mp3_44100_128`,
    {
      method: "POST",
      headers: { "xi-api-key": config.apiKey, "content-type": "application/json" },
      body: JSON.stringify({ text, model_id: config.modelId }),
      signal: AbortSignal.timeout(20_000),
    },
  )
  if (!res.ok) throw new Error(`elevenlabs ${res.status} ${(await res.text()).slice(0, 300)}`)
  const file = join(tmpdir(), `limit-alert-${Date.now()}.mp3`)
  writeFileSync(file, Buffer.from(await res.arrayBuffer()))
  const ok = await run("/usr/bin/afplay", [file])
  try {
    unlinkSync(file)
  } catch {}
  if (!ok) throw new Error("afplay failed")
}

async function speak(text) {
  if (config.apiKey) {
    try {
      await speakElevenLabs(text)
      return
    } catch (err) {
      log("elevenlabs failed, system voice fallback:", String(err))
    }
  }
  if (!(await run("/usr/bin/say", ["-v", config.systemVoice, text]))) {
    await run("/usr/bin/say", [text])
  }
}

// Kilka procesów opencode (TUI + serwis) ładuje plugin i każdy widzi te same
// eventy. Lock-plik w tmpdir sprawia, że alert odpali tylko jeden z nich.
function claim(key) {
  try {
    mkdirSync(LOCK_DIR, { recursive: true })
  } catch {}
  const file = join(LOCK_DIR, key.replace(/[^\w.-]/g, "_"))
  try {
    if (Date.now() - statSync(file).mtimeMs < DEDUPE_MS) return false
    unlinkSync(file)
  } catch {
    // brak locka
  }
  try {
    closeSync(openSync(file, "wx"))
    return true
  } catch {
    return false
  }
}

const titles = new Map()

async function sessionTitle(ctx, sessionID) {
  if (!sessionID) return "bez nazwy"
  if (titles.has(sessionID)) return titles.get(sessionID)
  try {
    const info = await ctx.session.get({ sessionID })
    const title = info?.title || info?.data?.title
    if (title) {
      titles.set(sessionID, title)
      return title
    }
  } catch (err) {
    log("session.get failed:", String(err))
  }
  return "bez nazwy"
}

const HEADINGS = {
  limit: "Skończył się limit",
  error: "Zadanie stanęło",
  done: "Zadanie skończone",
}

async function alert(ctx, sessionID, kind, detail) {
  if (!claim(`${sessionID}-${kind}`)) return
  const title = await sessionTitle(ctx, sessionID)
  const heading = HEADINGS[kind]
  log("alert", kind, sessionID, title, detail)
  await notify(`OpenCode: ${heading}`, `${title}${detail ? ` — ${detail}` : ""}`)
  await speak(`${heading}. Zadanie: ${title}.`)
}

const isLimit = (status, message) =>
  status === 429 ||
  /rate.?limit|quota|usage limit|too many requests|insufficient.?(credit|balance|quota)/i.test(message || "")

function errorFrom(data) {
  const e = data?.error ?? data
  return {
    status: e?.status ?? e?.statusCode ?? e?.data?.statusCode,
    message: e?.message ?? e?.data?.message ?? (typeof e === "string" ? e : ""),
  }
}

export default {
  id: "limit-alert",

  async setup(ctx) {
    log("loaded")

    // Ponowienia po 429 — łapie limit, zanim sesja padnie.
    await ctx.session.hook("retry", async (event) => {
      const { status, message } = event?.error ?? {}
      if (isLimit(status, message)) void alert(ctx, event.sessionID, "limit", message)
    })

    const controller = new AbortController()
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          const type = event?.type
          const data = event?.data ?? event?.properties
          if (type?.startsWith("session.") && !NOISY.test(type)) log("event", type, data)
          const sessionID = data?.sessionID ?? data?.info?.id
          switch (type) {
            case "session.renamed":
              if (sessionID && data?.title) titles.set(sessionID, data.title)
              break
            case "session.updated":
              if (sessionID && data?.info?.title) titles.set(sessionID, data.info.title)
              break
            case "session.execution.failed":
            case "session.error": {
              const { status, message } = errorFrom(data)
              void alert(ctx, sessionID, isLimit(status, message) ? "limit" : "error", message)
              break
            }
            case "session.execution.succeeded":
              if (config.announceDone) void alert(ctx, sessionID, "done")
              break
          }
        }
      } catch {
        // stream zamknięty przy unload
      }
    })()

    return () => controller.abort()
  },
}
