// Pure parsing and formatting helpers for sonos.
// Everything from the helper (and so from the speakers) is untrusted: it is
// bounded and validated here, and the QML renders it as plain text only.

var MAX_GROUPS = 32
var MAX_MEMBERS = 16
var MAX_FAVORITES = 50
var MAX_TEXT = 200
var MAX_RAW = 512 * 1024

var GROUP_ID = /^RINCON_[0-9A-F]{12}\d{5}$/
// Album art is only ever loaded from a player on the LAN (port 1400).
var ART_URL = /^http:\/\/(10|172|192)\.\d{1,3}\.\d{1,3}\.\d{1,3}:1400\/[^\s"'<>\\]{1,2000}$/
var STATES = ["PLAYING", "PAUSED_PLAYBACK", "STOPPED", "TRANSITIONING", "NO_MEDIA_PRESENT"]
var SOURCES = ["tv", "linein", "airplay", "queue", "radio", "stream", "none"]

function text(value, max) {
  if (value === undefined || value === null) return ""
  var s = String(value).replace(/[\u0000-\u001f\u007f-\u009f]/g, "").trim()
  var limit = max || MAX_TEXT
  return s.length > limit ? s.substring(0, limit - 1) + "…" : s
}

function int(value, lo, hi, fallback) {
  var n = typeof value === "number" ? value : NaN
  if (!isFinite(n)) return fallback
  return Math.max(lo, Math.min(hi, Math.round(n)))
}

// true / false, or null when the player lacks the setting.
function triBool(value) {
  return value === true ? true : (value === false ? false : null)
}

function parseJson(raw) {
  var s = String(raw || "")
  if (s.length === 0 || s.length > MAX_RAW) return null
  try {
    var v = JSON.parse(s)
    return v && typeof v === "object" ? v : null
  } catch (e) {
    return null
  }
}

function parseGroup(g) {
  if (!g || typeof g !== "object" || !GROUP_ID.test(String(g.id))) return null
  var members = []
  if (Array.isArray(g.members)) {
    for (var i = 0; i < g.members.length && members.length < MAX_MEMBERS; i++) {
      var m = text(g.members[i], 60)
      if (m !== "") members.push(m)
    }
  }
  if (members.length === 0) return null
  var state = STATES.indexOf(g.state) >= 0 ? g.state : "STOPPED"
  var source = SOURCES.indexOf(g.source) >= 0 ? g.source : "none"
  var art = typeof g.art === "string" && ART_URL.test(g.art) ? g.art : ""
  return {
    id: String(g.id),
    members: members,
    speakers: int(g.speakers, 1, 64, members.length),
    state: state,
    source: source,
    title: text(g.title),
    artist: text(g.artist),
    album: text(g.album),
    station: text(g.station),
    art: art,
    position: int(g.position, 0, 86400, 0),
    duration: int(g.duration, 0, 86400, 0),
    volume: int(g.volume, 0, 100, -1),
    muted: g.muted === true,
    nightMode: triBool(g.nightMode),
    speech: triBool(g.speech)
  }
}

function parseStatus(raw) {
  var v = parseJson(raw)
  var out = { ok: false, groups: [] }
  if (!v || v.ok !== true || !Array.isArray(v.groups)) return out
  for (var i = 0; i < v.groups.length && out.groups.length < MAX_GROUPS; i++) {
    var g = parseGroup(v.groups[i])
    if (g) out.groups.push(g)
  }
  out.ok = out.groups.length > 0
  return out
}

// ok: plays; folder: nothing to play; offline: a LAN stream nobody serves any
// more; signedOut: its music service refused last time; failed: refused otherwise.
var FAV_STATUSES = ["ok", "folder", "offline", "signedOut", "failed"]

function parseFavorites(raw) {
  var v = parseJson(raw)
  var out = []
  if (!v || !Array.isArray(v.favorites)) return out
  for (var i = 0; i < v.favorites.length && i < MAX_FAVORITES; i++) {
    var f = v.favorites[i] || {}
    // The index is the favorite's position in the player's list, which the
    // helper uses to play it, so keep it even when the title is blank.
    out.push({
      index: i,
      title: text(f.title, 80),
      description: text(f.description, 80),
      status: FAV_STATUSES.indexOf(f.status) >= 0 ? f.status : "ok"
    })
  }
  return out
}

function groupName(g) {
  return g ? g.members.join(" + ") : ""
}

function isPlaying(g) {
  return !!g && (g.state === "PLAYING" || g.state === "TRANSITIONING")
}

// The group to show: the one picked in the panel, else the room named in the
// settings, else whichever is playing, else the first.
function pickGroup(groups, selectedId, preferredRoom) {
  if (!groups || groups.length === 0) return null
  var i
  for (i = 0; i < groups.length; i++) if (groups[i].id === selectedId) return groups[i]
  var want = String(preferredRoom || "").trim().toLowerCase()
  if (want !== "") {
    for (i = 0; i < groups.length; i++) {
      for (var j = 0; j < groups[i].members.length; j++) {
        if (groups[i].members[j].toLowerCase() === want) return groups[i]
      }
    }
  }
  for (i = 0; i < groups.length; i++) if (isPlaying(groups[i])) return groups[i]
  return groups[0]
}

// What the panel headline shows. `kind` picks a translated title for the
// sources that have no track metadata.
function nowPlaying(g) {
  if (!g) return { kind: "none", title: "", subtitle: "" }
  if (g.source === "tv") return { kind: "tv", title: "", subtitle: "" }
  if (g.source === "linein") return { kind: "linein", title: "", subtitle: "" }
  // AirPlay from this PC carries no track details; Spotify Connect does.
  if (g.source === "airplay" && g.title === "") return { kind: "airplay", title: "", subtitle: "" }
  if (g.title === "" && g.station === "") return { kind: "idle", title: "", subtitle: "" }
  if (g.source === "radio") {
    var line = g.artist !== "" ? g.artist + " — " + g.title : g.title
    if (g.station === "") return { kind: "track", title: g.title, subtitle: g.artist }
    return { kind: "track", title: g.station, subtitle: line === g.station ? "" : line }
  }
  var sub = g.artist
  if (g.album !== "") sub = sub !== "" ? sub + " — " + g.album : g.album
  return { kind: "track", title: g.title, subtitle: sub }
}

// Next/previous only make sense when the group plays from its queue.
function canSkip(g) {
  return !!g && g.source === "queue"
}

function canSeek(g) {
  return !!g && g.source === "queue" && g.duration > 0
}

// Only home-theatre players (Beam, Arc, Ray, Playbar...) report night sound.
function isHomeTheatre(g) {
  return !!g && g.nightMode !== null
}

// Position interpolated between status polls while a track plays.
function livePosition(base, stampMs, nowMs, playing, duration) {
  var p = base
  if (playing) p += Math.max(0, (nowMs - stampMs) / 1000)
  if (duration > 0) p = Math.min(p, duration)
  return Math.max(0, Math.floor(p))
}

function formatTime(sec) {
  var s = Math.max(0, Math.floor(sec || 0))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var r = s % 60
  var pad = function(n) { return n < 10 ? "0" + n : String(n) }
  return h > 0 ? h + ":" + pad(m) + ":" + pad(r) : m + ":" + pad(r)
}

function settingInt(value, lo, hi, fallback) {
  var n = parseInt(String(value), 10)
  if (isNaN(n)) n = fallback
  return Math.max(lo, Math.min(hi, n))
}

function intervalMs(value) {
  return settingInt(value, 2, 120, 10) * 1000
}

function volumeStep(value) {
  return settingInt(value, 1, 10, 2)
}

// Pending wheel steps are sent as one relative change, bounded to a sane jump.
function wheelAdjustment(steps, step) {
  return Math.max(-20, Math.min(20, steps * step))
}

// Apps playing audio on this PC, from `sonos apps`: which ones go to the
// Sonos over AirPlay. ok is false when the Sonos isn't an output (no AirPlay).
var MAX_APPS = 32
function parseApps(raw) {
  var v = parseJson(raw)
  var out = { ok: false, sink: "", apps: [] }
  if (!v || v.ok !== true || !Array.isArray(v.apps)) return out
  for (var i = 0; i < v.apps.length && out.apps.length < MAX_APPS; i++) {
    var a = v.apps[i] || {}
    var name = text(a.name, 60)
    if (name === "") continue
    out.apps.push({ name: name, onSonos: a.onSonos === true, playing: a.playing === true })
  }
  out.ok = true
  out.sink = text(v.sink, 60)
  return out
}

// Short service name for a favorite row: "TuneIn Station" -> "TuneIn",
// "From Apple Music" -> "Apple Music". Tells duplicates apart.
function serviceLabel(description) {
  var d = text(description, 80)
  d = d.replace(/^From\s+/i, "").replace(/\s+(Radio\s+)?Station$/i, "")
  return d
}

function isRadioFavorite(f) {
  return !!f && /radio|station/i.test(f.description)
}

// The source tab that matches what the group is playing.
function tabFor(g, hasTv, hasPc) {
  if (g && g.source === "tv" && hasTv) return "tv"
  if (g && g.source === "airplay" && hasPc) return "pc"
  return "favorites"
}

// What the source line under the title says.
function sourceKind(g) {
  if (!g) return ""
  if (g.source === "radio") return "radio"
  if (g.source === "queue") return "queue"
  return g.source === "none" ? "" : g.source
}
