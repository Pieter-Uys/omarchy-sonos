// Run with: node --test ~/.config/omarchy/plugins/pieter.sonos/tests/
const test = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const root = path.join(__dirname, "..")
const M = {}
vm.runInNewContext(fs.readFileSync(path.join(root, "Model.js"), "utf8"), M)

const ID = "RINCON_000E58A1B2C301400"
const group = (over) => Object.assign({
  id: ID, members: ["TV Room"], speakers: 3, state: "PLAYING", source: "queue",
  title: "Shallow", artist: "Lady Gaga", album: "A Star Is Born", station: "",
  art: "http://192.168.1.20:1400/getaa?s=1&u=x", position: 30, duration: 215,
  volume: 36, muted: false, nightMode: false, speech: true
}, over)
const status = (...groups) => JSON.stringify({ ok: true, groups })
const plain = (v) => JSON.parse(JSON.stringify(v))

test("parses a status response", () => {
  const s = M.parseStatus(status(group()))
  assert.strictEqual(s.ok, true)
  const g = s.groups[0]
  assert.strictEqual(g.id, ID)
  assert.strictEqual(g.volume, 36)
  assert.strictEqual(g.speech, true)
  assert.strictEqual(g.nightMode, false)
  assert.strictEqual(M.isHomeTheatre(g), true)
  assert.deepStrictEqual(plain(M.nowPlaying(g)), { kind: "track", title: "Shallow", subtitle: "Lady Gaga — A Star Is Born" })
})

test("rejects malformed and hostile input", () => {
  assert.strictEqual(M.parseStatus("not json").ok, false)
  assert.strictEqual(M.parseStatus("").ok, false)
  assert.strictEqual(M.parseStatus(JSON.stringify({ ok: true, groups: [{ id: "bad", members: ["x"] }] })).ok, false)
  const g = M.parseStatus(status(group({ volume: 900, position: -5, state: "EXPLODING", source: "evil", speakers: "lots" }))).groups[0]
  assert.strictEqual(g.volume, 100)
  assert.strictEqual(g.position, 0)
  assert.strictEqual(g.state, "STOPPED")
  assert.strictEqual(g.source, "none")
  assert.strictEqual(g.speakers, 1)
})

test("keeps markup-shaped titles as literal text, strips control characters, bounds length", () => {
  const markup = '<img src="https://example.invalid/tracker">'
  const g = M.parseStatus(status(group({ title: markup + "\u0007", artist: "x".repeat(5000) }))).groups[0]
  assert.strictEqual(g.title, markup)
  assert.ok(g.artist.length <= M.MAX_TEXT)
  const fav = M.parseFavorites(JSON.stringify({ favorites: [{ title: "<b>Hi</b>", description: "TuneIn Station" }] }))
  assert.strictEqual(fav[0].title, "<b>Hi</b>")
})

test("only loads album art from a LAN player", () => {
  const ok = M.parseStatus(status(group())).groups[0]
  assert.ok(ok.art.startsWith("http://192.168.1.20:1400/"))
  for (const art of ["https://example.com/a.jpg", "http://8.8.8.8:1400/getaa", "file:///etc/passwd", "http://192.168.0.1:80/x", 'http://192.168.0.1:1400/"><script>']) {
    assert.strictEqual(M.parseStatus(status(group({ art }))).groups[0].art, "", art)
  }
})

test("headline per source", () => {
  assert.strictEqual(M.nowPlaying(group({ source: "tv" })).kind, "tv")
  assert.strictEqual(M.nowPlaying(group({ source: "linein" })).kind, "linein")
  assert.strictEqual(M.nowPlaying(group({ title: "", station: "", source: "none" })).kind, "idle")
  assert.deepStrictEqual(plain(M.nowPlaying(group({ source: "radio", station: "Classic FM", title: "Clair de Lune", artist: "Debussy", album: "" }))),
    { kind: "track", title: "Classic FM", subtitle: "Debussy — Clair de Lune" })
  assert.strictEqual(M.canSkip(group({ source: "radio" })), false)
  assert.strictEqual(M.canSeek(group({ source: "queue", duration: 0 })), false)
  assert.strictEqual(M.isHomeTheatre(group({ nightMode: null })), false)
})

test("picks the selected, preferred, playing, then first group", () => {
  const a = group({ id: "RINCON_AAAAAAAAAAAA01400", members: ["Kitchen"], state: "STOPPED" })
  const b = group({ id: "RINCON_BBBBBBBBBBBB01400", members: ["Office"], state: "PLAYING" })
  assert.strictEqual(M.pickGroup([a, b], a.id, "").id, a.id)
  assert.strictEqual(M.pickGroup([a, b], "", "office").id, b.id)
  assert.strictEqual(M.pickGroup([a, b], "", "").id, b.id)
  assert.strictEqual(M.pickGroup([a, group({ id: b.id, state: "STOPPED" })], "", "").id, a.id)
  assert.strictEqual(M.pickGroup([], "", ""), null)
})

test("favorites keep their index for playback", () => {
  const f = M.parseFavorites(JSON.stringify({ ok: true, favorites: [{ title: "A" }, { title: "" }, { title: "C" }] }))
  assert.deepStrictEqual(plain(f.map((x) => x.index)), [0, 1, 2])
  assert.strictEqual(M.parseFavorites(JSON.stringify({ favorites: new Array(500).fill({ title: "x" }) })).length, M.MAX_FAVORITES)
})

test("time, interpolation and settings", () => {
  assert.strictEqual(M.formatTime(65), "1:05")
  assert.strictEqual(M.formatTime(3725), "1:02:05")
  assert.strictEqual(M.livePosition(30, 1000, 6000, true, 215), 35)
  assert.strictEqual(M.livePosition(30, 1000, 6000, false, 215), 30)
  assert.strictEqual(M.livePosition(210, 0, 60000, true, 215), 215)
  assert.strictEqual(M.intervalMs("abc"), 10000)
  assert.strictEqual(M.intervalMs(1), 2000)
  assert.strictEqual(M.volumeStep(50), 10)
  assert.strictEqual(M.wheelAdjustment(30, 2), 20)
})

test("shows AirPlay from this PC by name, and keeps Spotify Connect track details", () => {
  const pc = M.parseStatus(status(group({ source: "airplay", title: "", artist: "", album: "" }))).groups[0]
  assert.strictEqual(M.nowPlaying(pc).kind, "airplay")
  assert.strictEqual(M.canSkip(pc), false)
  const sc = M.parseStatus(status(group({ source: "airplay" }))).groups[0]
  assert.strictEqual(M.nowPlaying(sc).kind, "track")
})

test("parses the apps that can play on the Sonos", () => {
  const raw = JSON.stringify({ ok: true, sink: "TV Room", apps: [
    { name: "Spotify", onSonos: true, playing: true },
    { name: "<img src=x>", onSonos: "yes", playing: 1 },
    { name: "" }
  ] })
  const a = M.parseApps(raw)
  assert.strictEqual(a.ok, true)
  assert.strictEqual(a.sink, "TV Room")
  assert.strictEqual(a.apps.length, 2)
  assert.deepStrictEqual(plain(a.apps[0]), { name: "Spotify", onSonos: true, playing: true })
  assert.strictEqual(a.apps[1].onSonos, false)
  assert.strictEqual(M.parseApps("nope").ok, false)
  assert.strictEqual(M.parseApps(JSON.stringify({ ok: false, apps: [] })).ok, false)
})
