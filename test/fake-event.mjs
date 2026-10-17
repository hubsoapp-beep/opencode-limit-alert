// Symuluje event "Rate limit exceeded" bez uruchamiania opencode.
// Uruchom: node test/fake-event.mjs  (czyta ~/.config/opencode/limit-alert.json)
import { copyFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const src = new URL("../limit-alert.js", import.meta.url)
const copy = join(tmpdir(), `limit-alert-test-${Date.now()}.mjs`)
copyFileSync(src, copy)
rmSync(join(tmpdir(), "limit-alert-locks"), { recursive: true, force: true })
const plugin = (await import(copy)).default

const events = [
  { type: "session.execution.failed", data: { sessionID: "test", error: { message: "Rate limit exceeded. Please try again later." } } },
]
await plugin.setup({
  session: { hook: async () => {}, get: async () => ({ title: "Testowe zadanie" }) },
  event: { subscribe: async function* () { yield* events } },
})
setTimeout(() => rmSync(copy, { force: true }), 15_000)
