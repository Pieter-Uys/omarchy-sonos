import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Sonos: control the Sonos speakers on the local network from the bar.
// All player traffic goes through the bundled bin/sonos helper, which talks
// only to players on the LAN (UPnP, port 1400); no Sonos account or cloud.
// Every string from the speakers is bounded in Model.js and shown as plain text.
//
// Bar icon: click opens the panel, middle-click plays/pauses, right-click
// mutes, scroll changes the volume.
Panel {
  id: root
  moduleName: "sonos"
  ipcTarget: "sonos"
  manageIpc: false

  readonly property string helperPath: String(Qt.resolvedUrl("bin/sonos")).replace(/^file:\/\//, "")

  readonly property string glyphSpeaker: String.fromCodePoint(0xF04C3)
  readonly property string glyphSpeakerOff: String.fromCodePoint(0xF04C4)
  readonly property string glyphPlay: String.fromCodePoint(0xF040A)
  readonly property string glyphPause: String.fromCodePoint(0xF03E4)
  readonly property string glyphPrev: String.fromCodePoint(0xF04AE)
  readonly property string glyphNext: String.fromCodePoint(0xF04AD)
  readonly property string glyphTv: String.fromCodePoint(0xF0502)
  readonly property string glyphMusic: String.fromCodePoint(0xF075A)
  readonly property string glyphVolume: String.fromCodePoint(0xF057E)
  readonly property string glyphMuted: String.fromCodePoint(0xF0581)
  readonly property string glyphRadio: String.fromCodePoint(0xF0439)
  readonly property string glyphAlbum: String.fromCodePoint(0xF0025)

  readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  readonly property int intervalMs: Model.intervalMs(setting("refreshIntervalSec", 10))
  readonly property int volumeStep: Model.volumeStep(setting("volumeStep", 2))
  readonly property string preferredRoom: String(setting("room", ""))

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---------- state ----------

  property var status: ({ ok: false, groups: [] })
  property bool loaded: false
  property string selectedId: ""
  readonly property var group: Model.pickGroup(root.status.groups, root.selectedId, root.preferredRoom)
  readonly property bool playing: Model.isPlaying(root.group)
  readonly property var nowPlaying: Model.nowPlaying(root.group)

  property var favorites: []
  property bool favoritesLoaded: false

  // Apps on this PC that can play on the Sonos over AirPlay.
  property var pcAudio: ({ ok: false, sink: "", apps: [] })
  property var appOverrides: ({})
  function appOnSonos(app) {
    return root.appOverrides[app.name] !== undefined ? root.appOverrides[app.name] : app.onSonos
  }

  // Optimistic values shown until a status read taken after the change lands.
  property var overrides: ({})
  function current(key) {
    if (root.overrides[key] !== undefined) return root.overrides[key]
    return root.group ? root.group[key] : null
  }
  function override(key, value) {
    var o = Object.assign({}, root.overrides)
    o[key] = value
    root.overrides = o
  }
  readonly property int volume: { var v = current("volume"); return v === null ? -1 : v }
  readonly property bool muted: current("muted") === true

  // Track position, interpolated between polls.
  property int positionBase: 0
  property real positionStamp: Date.now()
  property real nowMs: Date.now()
  property bool seeking: false
  property int seekPreview: 0
  readonly property int livePosition: root.seeking ? root.seekPreview
    : Model.livePosition(root.positionBase, root.positionStamp, root.nowMs, root.playing, root.group ? root.group.duration : 0)

  // ---------- helper processes ----------

  property var queue: []
  property bool statusClean: true
  property bool refreshAgain: false
  property real wheelAccumulator: 0

  function refresh() {
    if (statusProc.running) { root.refreshAgain = true; return }
    // A read that overlaps an action could carry the old value, so it does
    // not replace the optimistic overrides.
    root.statusClean = root.queue.length === 0 && !actionProc.running
    statusProc.running = true
  }

  function refreshApps() {
    if (!root.group || appsProc.running || sendProc.running) return
    appsProc.command = ["python3", "-I", root.helperPath, "apps", root.group.id]
    appsProc.running = true
  }

  // Play/pause/skip the app on this PC that is sending to the Sonos.
  function pcControl(command) {
    if (!root.pcNow || pcControlProc.running) return
    if (command === "play-pause") {
      var apps = root.pcAudio.apps.map(function(a) {
        if (a.name !== root.pcNow.app || !a.track) return a
        var t = Object.assign({}, a.track, { status: a.track.status === "Playing" ? "Paused" : "Playing" })
        return Object.assign({}, a, { track: t })
      })
      root.pcAudio = Object.assign({}, root.pcAudio, { apps: apps })
    }
    pcControlProc.command = ["python3", "-I", root.helperPath, "pc", root.pcNow.app, command]
    pcControlProc.running = true
  }

  property var sendQueue: []
  function sendApp(name, on) {
    if (!root.group) return
    var o = Object.assign({}, root.appOverrides)
    o[name] = on
    root.appOverrides = o
    root.sendQueue = root.sendQueue.concat([[root.group.id, name, on ? "1" : "0"]])
    pumpSend()
  }
  function pumpSend() {
    if (sendProc.running || root.sendQueue.length === 0) return
    var q = root.sendQueue.slice()
    var next = q.shift()
    root.sendQueue = q
    sendProc.command = ["python3", "-I", root.helperPath, "send"].concat(next)
    sendProc.running = true
  }

  function refreshFavorites() {
    if (!favProc.running) favProc.running = true
  }

  function onStatus(raw) {
    root.loaded = true
    if (!root.statusClean) { root.refresh(); return }
    var next = Model.parseStatus(raw)
    root.status = next
    root.overrides = ({})
    var g = Model.pickGroup(next.groups, root.selectedId, root.preferredRoom)
    if (g) {
      root.positionBase = g.position
      root.positionStamp = Date.now()
      root.nowMs = root.positionStamp
    }
  }

  function action(name, arg) {
    if (!root.group) return
    var id = root.group.id
    var q = root.queue.slice()
    var last = q.length > 0 ? q[q.length - 1] : null
    // Coalesce volume changes so a drag or a fast scroll sends one command.
    if (last && last[1] === id && name === "volume" && last[0] === "volume") q.pop()
    else if (last && last[1] === id && name === "volume-rel" && last[0] === "volume-rel") {
      q.pop()
      arg = Math.max(-100, Math.min(100, parseInt(last[2], 10) + arg))
    }
    q.push(arg === undefined ? [name, id] : [name, id, String(arg)])
    root.queue = q
    pump()
  }

  // Feedback for the last command that failed, and the favorite that is loading.
  property string notice: ""
  property int pendingFavorite: -1
  property var runningCommand: null

  function playFavorite(fav) {
    if (!root.group || root.pendingFavorite >= 0) return
    root.notice = ""
    root.pendingFavorite = fav.index
    root.action("favorite", fav.index)
  }

  function favoriteTitle(index) {
    for (var i = 0; i < root.favorites.length; i++) {
      if (root.favorites[i].index === index) return root.favorites[i].title || strings.t("untitled")
    }
    return strings.t("untitled")
  }

  function onActionExit(code) {
    var cmd = root.runningCommand
    root.runningCommand = null
    if (cmd && cmd[0] === "favorite") {
      var title = root.favoriteTitle(parseInt(cmd[2], 10))
      root.pendingFavorite = -1
      if (code === 4) root.notice = strings.t("favoriteServiceError").arg(title)
      else if (code !== 0) root.notice = strings.t("favoriteError").arg(title)
    } else if (cmd && cmd[0] === "music" && code !== 0) {
      root.notice = code === 2 ? strings.t("actionUnreachable")
        : code === 5 ? strings.t("nothingToResume") : strings.t("musicResumeError")
    } else if (code === 2) {
      root.notice = strings.t("actionUnreachable")
    }
    if (code !== 0) {
      root.overrides = ({})
      noticeTimer.restart()
    }
    root.pump()
  }

  function pump() {
    if (actionProc.running) return
    if (root.queue.length === 0) { root.refresh(); return }
    var q = root.queue.slice()
    var next = q.shift()
    root.queue = q
    root.runningCommand = next
    actionProc.command = ["python3", "-I", root.helperPath].concat(next)
    actionProc.running = true
  }

  Timer {
    id: noticeTimer
    interval: 8000
    onTriggered: root.notice = ""
  }

  function togglePlay() {
    if (!root.group) return
    root.override("state", root.playing ? "PAUSED_PLAYBACK" : "PLAYING")
    root.action("toggle")
  }

  function setVolume(v) {
    var n = Math.max(0, Math.min(100, Math.round(v)))
    root.override("volume", n)
    root.action("volume", n)
  }

  function nudgeVolume(steps) {
    if (!root.group || root.volume < 0) return
    var adj = Model.wheelAdjustment(steps, root.volumeStep)
    root.override("volume", Math.max(0, Math.min(100, root.volume + adj)))
    root.action("volume-rel", adj)
  }

  function toggleMute() {
    if (!root.group) return
    var next = !root.muted
    root.override("muted", next)
    root.action("mute", next ? 1 : 0)
  }

  function toggleSetting(key, actionName) {
    var next = current(key) !== true
    root.override(key, next)
    root.action(actionName, next ? 1 : 0)
  }

  Process {
    id: statusProc
    command: ["python3", "-I", root.helperPath, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onStatus(text)
    }
    onExited: if (root.refreshAgain) { root.refreshAgain = false; root.refresh() }
  }

  Process {
    id: favProc
    command: ["python3", "-I", root.helperPath, "favorites"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.favorites = Model.parseFavorites(text)
        root.favoritesLoaded = true
      }
    }
  }

  Process {
    id: appsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.pcAudio = Model.parseApps(text)
        if (root.sendQueue.length === 0 && !sendProc.running) root.appOverrides = ({})
      }
    }
  }

  Process {
    id: pcControlProc
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.notice = strings.t("pcControlError"); noticeTimer.restart() }
      pcRefreshTimer.restart()
    }
  }

  // Track changes take the app a moment to report.
  Timer {
    id: pcRefreshTimer
    interval: 400
    onTriggered: root.refreshApps()
  }

  Process {
    id: sendProc
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.notice = strings.t("sendError")
        noticeTimer.restart()
        root.appOverrides = ({})
      }
      if (root.sendQueue.length > 0) root.pumpSend()
      else root.refreshApps()
    }
  }

  Process {
    id: actionProc
    onExited: function(exitCode) { root.onActionExit(exitCode) }
  }

  // Poll slowly in the background for the bar icon, quickly while the panel is open.
  Timer {
    interval: root.opened ? 2000 : root.intervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: { root.refresh(); if (root.opened) root.refreshApps() }
  }

  Timer {
    interval: 1000
    running: root.opened && root.playing
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  onOpenedChanged: if (opened) { tabPicked = false; syncTab(); refresh(); refreshFavorites(); refreshApps() }
  onGroupChanged: syncTab()

  ShellIpc {
    target: "sonos"
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function playPause() { root.togglePlay() }
    function next() { root.action("next") }
    function previous() { root.action("previous") }
    function volumeUp() { root.nudgeVolume(1) }
    function volumeDown() { root.nudgeVolume(-1) }
    function mute() { root.toggleMute() }
  }

  // ---------- text ----------

  function stateText(state) {
    if (state === "PLAYING" || state === "TRANSITIONING") return strings.t("playing")
    if (state === "PAUSED_PLAYBACK") return strings.t("paused")
    return strings.t("stopped")
  }

  readonly property var pcNow: Model.pcTrack(root.group, root.pcAudio)

  function headline() {
    if (root.pcNow) return root.pcNow.track.title
    var np = root.nowPlaying
    if (np.kind === "tv") return strings.t("tv")
    if (np.kind === "linein") return strings.t("lineIn")
    if (np.kind === "airplay") return strings.t("airplay")
    if (np.kind === "idle" || np.kind === "none") return strings.t("nothingPlaying")
    return np.title
  }

  readonly property string barTooltip: {
    if (root.opened) return ""
    if (!root.loaded) return strings.t("searching")
    if (!root.group) return strings.t("notFound")
    var room = Model.groupName(root.group)
    if (!root.playing) return strings.t("tooltipIdle").arg(room).arg(root.stateText(root.group.state))
    return strings.t("tooltipPlaying").arg(room).arg(root.headline())
  }

  // ---------- bar ----------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.muted ? root.glyphSpeakerOff : root.glyphSpeaker
    foreground: root.group ? root.fg : Qt.darker(root.fg, 1.6)
    tooltipText: root.barTooltip
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.togglePlay()
      else if (b === Qt.RightButton) root.toggleMute()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps !== 0) root.nudgeVolume(wheel.steps)
    }
  }

  // ---------- layout: full (source tabs) or minimal (collapsed sections) ----------

  readonly property string glyphChevronDown: String.fromCodePoint(0xF0140)
  readonly property string glyphChevronRight: String.fromCodePoint(0xF0142)

  // Applied locally first so the panel redraws on the click, then written to
  // this widget's shell.json entry so it sticks (same as the built-in panels).
  property string layoutOverride: ""
  readonly property string layout: {
    var v = root.layoutOverride !== "" ? root.layoutOverride : String(setting("layout", "full"))
    return v === "minimal" ? "minimal" : "full"
  }
  function setLayout(value) {
    root.layoutOverride = value
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.layout = value
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  readonly property bool hasTv: Model.isHomeTheatre(root.group)
  readonly property bool hasPc: root.pcAudio.ok
  readonly property var sections: {
    var out = [{ key: "favorites", label: strings.t("tabFavorites") }]
    if (root.hasTv) out.push({ key: "tv", label: strings.t("tabTv") })
    if (root.hasPc) out.push({ key: "pc", label: strings.t("tabPc") })
    return out
  }

  // Full layout: the open tab. It follows what is playing until picked by hand.
  property string tab: "favorites"
  property bool tabPicked: false
  function syncTab() {
    if (!root.tabPicked) root.tab = Model.tabFor(root.group, root.hasTv, root.hasPc)
  }
  readonly property string shownTab: root.sections.some(function(s) { return s.key === root.tab }) ? root.tab : "favorites"
  onHasPcChanged: syncTab()

  // Minimal layout: which sections are expanded (all closed to start).
  property var expanded: ({})
  function toggleSection(key) {
    var e = Object.assign({}, root.expanded)
    e[key] = !e[key]
    root.expanded = e
  }

  function sectionSummary(key) {
    if (key === "favorites")
      return root.favoritesLoaded ? Commons.I18n.formatNumber(root.favorites.length) : ""
    if (key === "tv") return root.current("source") === "tv" ? strings.t("summaryOn") : strings.t("summaryOff")
    if (key === "pc") {
      var n = 0
      for (var i = 0; i < root.pcAudio.apps.length; i++) if (root.appOnSonos(root.pcAudio.apps[i])) n++
      return strings.tn("summaryOnSonos", n).arg(Commons.I18n.formatNumber(n))
    }
    return ""
  }

  function sourceLine() {
    var g = root.group
    if (!g) return ""
    var state = root.stateText(root.current("state"))
    if (root.pcNow) {
      var st = root.pcNow.track.status === "Paused" ? strings.t("paused") : state
      return st + " · " + strings.t("airplayFrom").arg(root.pcNow.app)
    }
    var kind = Model.sourceKind(g)
    // TV, line-in and bare AirPlay already name the source in the title.
    if (kind === "radio") return state + " · " + strings.t("sourceRadio")
    if (kind === "airplay" && root.nowPlaying.kind === "track") return state + " · " + strings.t("airplay")
    return state
  }

  function favoriteClicked(fav) {
    if (fav.status === "folder" || fav.status === "offline") {
      root.notice = strings.t(fav.status === "folder" ? "favFolderNotice" : "favOfflineNotice")
        .arg(fav.title || strings.t("untitled"))
      noticeTimer.restart()
      return
    }
    root.playFavorite(fav)
  }

  function favoriteNote(fav) {
    if (fav.status === "folder") return strings.t("favFolder")
    if (fav.status === "offline") return strings.t("favOffline")
    if (fav.status === "signedOut") return strings.t("favSignedOut")
    if (fav.status === "failed") return strings.t("favFailed")
    return Model.serviceLabel(fav.description)
  }

  // ---------- panel ----------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.pcNow ? root.pcControl("play-pause") : root.togglePlay()
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.nudgeVolume(-dy)
        else if (dx !== 0 && root.pcNow) root.pcControl(dx > 0 ? "next" : "previous")
        else if (dx !== 0 && Model.canSkip(root.group)) root.action(dx > 0 ? "next" : "previous")
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ----- header: room, speaker count, layout switch -----
        PanelHero {
          width: parent.width
          foreground: root.fg
          fontFamily: root.fontFamily
          title: root.group ? Model.groupName(root.group) : strings.t("title")
          meta: root.group
            ? strings.tn("speakers", root.group.speakers).arg(Commons.I18n.formatNumber(root.group.speakers))
            : ""
          iconComponent: PlainText {
            text: root.glyphSpeaker
            font.pixelSize: Style.font.display
          }
          trailingControl: Button {
            visible: !!root.group
            text: root.layout === "full" ? strings.t("layoutMinimal") : strings.t("layoutFull")
            tooltipText: strings.t("layoutTip")
            foreground: root.fg
            accent: root.accent
            fontSize: Style.font.caption
            onClicked: root.setLayout(root.layout === "full" ? "minimal" : "full")
          }
        }

        // ----- not found / searching -----
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: !root.group

          PlainText {
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.loaded ? strings.t("notFoundDetail") : strings.t("searching")
            opacity: 0.7
          }

          Button {
            visible: root.loaded
            text: strings.t("retry")
            foreground: root.fg
            accent: root.accent
            bordered: true
            onClicked: root.refresh()
          }
        }

        // ----- room picker (only with more than one group) -----
        ButtonGroup {
          visible: root.status.groups.length > 1
          foreground: root.fg
          accent: root.accent
          fontFamily: root.fontFamily
          focusable: false
          value: root.group ? root.group.id : ""
          options: root.status.groups.map(function(g) { return { value: g.id, label: Model.groupName(g) } })
          onChanged: function(v) { root.selectedId = v; root.overrides = ({}); root.refresh() }
        }

        // ===== player: now playing, progress, transport, volume =====
        Row {
          visible: !!root.group
          width: parent.width
          spacing: Style.space(12)

          BorderSurface {
            id: artTile
            width: Style.space(64)
            height: Style.space(64)
            radius: Style.spacing.labelGap
            color: Style.normalFillFor(root.fg, root.accent)
            borderSpec: Border.controlSpec("normal", root.fg, root.accent)

            Image {
              id: art
              anchors.fill: parent
              anchors.margins: Style.space(2)
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: true
              source: root.group ? root.group.art : ""
              visible: status === Image.Ready
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
            }

            PlainText {
              anchors.centerIn: parent
              visible: art.status !== Image.Ready
              text: root.nowPlaying.kind === "tv" ? root.glyphTv
                : (root.nowPlaying.kind === "airplay" ? root.glyphSpeaker : root.glyphMusic)
              opacity: 0.5
              font.pixelSize: Style.font.displayLarge
            }
          }

          Column {
            width: parent.width - artTile.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(3)

            PlainText {
              width: parent.width
              text: root.headline()
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
              maximumLineCount: 2
              wrapMode: Text.WordWrap
            }

            PlainText {
              width: parent.width
              text: root.pcNow
                ? [root.pcNow.track.artist, root.pcNow.track.album].filter(function(x) { return x !== "" }).join(" — ")
                : (root.nowPlaying.kind === "idle" ? strings.t("pickFavorite") : root.nowPlaying.subtitle)
              visible: text !== ""
              opacity: 0.7
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            PlainText {
              width: parent.width
              text: root.sourceLine()
              visible: text !== ""
              opacity: 0.5
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: Model.canSeek(root.group)

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 0
            maximum: Math.max(1, root.group ? root.group.duration : 1)
            step: 5
            value: root.livePosition
            fillColor: root.accent
            onDraggingChanged: root.seeking = dragging
            onMoved: function(v) { root.seekPreview = Math.round(v) }
            onReleased: function(v) {
              root.positionBase = Math.round(v)
              root.positionStamp = Date.now()
              root.nowMs = root.positionStamp
              root.action("seek", Math.round(v))
            }
          }

          Item {
            width: parent.width
            implicitHeight: elapsed.implicitHeight

            PlainText {
              id: elapsed
              anchors.left: parent.left
              text: Model.formatTime(root.livePosition)
              opacity: 0.6
              font.pixelSize: Style.font.caption
            }

            PlainText {
              anchors.right: parent.right
              text: Model.formatTime(root.group ? root.group.duration : 0)
              opacity: 0.6
              font.pixelSize: Style.font.caption
            }
          }
        }

        Row {
          visible: !!root.group
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(4)

          Button {
            iconText: root.glyphPrev
            tooltipText: strings.t("previous")
            foreground: root.fg
            accent: root.accent
            enabled: Model.canSkip(root.group) || !!root.pcNow
            opacity: enabled ? 1 : 0.4
            onClicked: root.pcNow ? root.pcControl("previous") : root.action("previous")
          }

          Button {
            readonly property bool isPlaying: root.pcNow
              ? root.pcNow.track.status === "Playing" : root.current("state") === "PLAYING"
            iconText: isPlaying ? root.glyphPause : root.glyphPlay
            tooltipText: isPlaying ? strings.t("pause") : strings.t("play")
            foreground: root.fg
            accent: root.accent
            iconSize: Style.font.iconLarge
            horizontalPadding: Style.spacing.panelGap
            enabled: !!root.group && root.group.source !== "none"
            opacity: enabled ? 1 : 0.4
            onClicked: root.pcNow ? root.pcControl("play-pause") : root.togglePlay()
          }

          Button {
            iconText: root.glyphNext
            tooltipText: strings.t("next")
            foreground: root.fg
            accent: root.accent
            enabled: Model.canSkip(root.group) || !!root.pcNow
            opacity: enabled ? 1 : 0.4
            onClicked: root.pcNow ? root.pcControl("next") : root.action("next")
          }
        }

        // Feedback: favorite loading, or why the last command failed.
        PlainText {
          width: parent.width
          visible: text !== ""
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
          text: root.pendingFavorite >= 0
            ? strings.t("favoriteStarting").arg(root.favoriteTitle(root.pendingFavorite))
            : root.notice
          color: root.notice !== "" && root.pendingFavorite < 0 ? Commons.Color.urgent : root.fg
          opacity: root.pendingFavorite >= 0 ? 0.7 : 1
          font.pixelSize: Style.font.bodySmall
        }

        Row {
          visible: !!root.group && root.volume >= 0
          width: parent.width
          spacing: Style.space(8)

          Button {
            id: muteButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.muted ? root.glyphMuted : root.glyphVolume
            tooltipText: root.muted ? strings.t("unmute") : strings.t("mute")
            foreground: root.fg
            accent: root.accent
            selected: root.muted
            onClicked: root.toggleMute()
          }

          PanelSlider {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - muteButton.width - volumeLabel.width - parent.spacing * 2
            bar: root.bar
            minimum: 0
            maximum: 100
            step: root.volumeStep
            integer: true
            value: Math.max(0, root.volume)
            opacity: root.muted ? 0.5 : 1
            onMoved: function(v) { root.override("volume", Math.round(v)) }
            onReleased: function(v) { root.setVolume(v) }
            onRightClicked: root.toggleMute()
          }

          PlainText {
            id: volumeLabel
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(32)
            horizontalAlignment: Text.AlignRight
            text: Commons.I18n.formatNumber(Math.max(0, root.volume))
            font.pixelSize: Style.font.bodySmall
            opacity: 0.7
          }
        }

        PanelSeparator {
          visible: !!root.group
          width: parent.width
          foreground: root.fg
        }

        // ===== sources: where the sound comes from =====

        // Full: one tab per source.
        Column {
          visible: !!root.group && root.layout === "full"
          width: parent.width
          spacing: Style.space(10)

          ButtonGroup {
            visible: root.sections.length > 1
            foreground: root.fg
            accent: root.accent
            fontFamily: root.fontFamily
            focusable: false
            value: root.shownTab
            options: root.sections.map(function(s) { return { value: s.key, label: s.label } })
            onChanged: function(v) { root.tab = v; root.tabPicked = true }
          }

          Loader {
            width: parent.width
            sourceComponent: root.shownTab === "tv" ? tvSection
              : (root.shownTab === "pc" ? pcSection : favoritesSection)
          }
        }

        // Minimal: each source is a one-line row that expands.
        Column {
          visible: !!root.group && root.layout === "minimal"
          width: parent.width
          spacing: Style.space(2)

          Repeater {
            model: root.sections

            delegate: Column {
              required property var modelData
              width: parent.width
              spacing: Style.space(6)

              Button {
                width: parent.width
                leftAlign: true
                iconText: root.expanded[modelData.key] ? root.glyphChevronDown : root.glyphChevronRight
                text: modelData.label
                foreground: root.fg
                accent: root.accent
                fontSize: Style.font.bodySmall
                onClicked: root.toggleSection(modelData.key)

                PlainText {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.controlPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.sectionSummary(modelData.key)
                  opacity: 0.5
                  font.pixelSize: Style.font.caption
                }
              }

              Loader {
                active: !!root.expanded[modelData.key]
                visible: active
                width: parent.width
                sourceComponent: modelData.key === "tv" ? tvSection
                  : (modelData.key === "pc" ? pcSection : favoritesSection)
              }
            }
          }
        }
      }
    }
  }

  // ---------- source sections (shared by both layouts) ----------

  Component {
    id: favoritesSection

    Column {
      spacing: Style.space(4)

      PlainText {
        visible: !root.favoritesLoaded || root.favorites.length === 0
        text: root.favoritesLoaded ? strings.t("noFavorites") : strings.t("loading")
        opacity: 0.6
        font.pixelSize: Style.font.bodySmall
      }

      ListView {
        id: favList
        visible: root.favorites.length > 0
        width: parent.width
        height: Math.min(contentHeight, Style.space(root.layout === "full" ? 300 : 220))
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        spacing: Style.space(1)
        model: root.favorites

        delegate: Item {
          id: favRow
          required property var modelData
          readonly property bool usable: modelData.status === "ok"
          readonly property bool pending: root.pendingFavorite === modelData.index
          width: favList.width
          height: Style.space(30)

          Rectangle {
            anchors.fill: parent
            radius: Style.spacing.labelGap
            color: favRow.pending ? Style.selectedFillFor(root.fg, root.accent)
              : (favMouse.containsMouse ? Style.hoverFillFor(root.fg, root.accent) : "transparent")
          }

          PlainText {
            id: favIcon
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: Model.isRadioFavorite(favRow.modelData) ? root.glyphRadio : root.glyphAlbum
            opacity: favRow.usable ? 0.8 : 0.35
          }

          PlainText {
            anchors.left: favIcon.right
            anchors.leftMargin: Style.space(8)
            anchors.right: favNote.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: favRow.modelData.title !== "" ? favRow.modelData.title : strings.t("untitled")
            elide: Text.ElideRight
            font.pixelSize: Style.font.bodySmall
            opacity: favRow.usable ? 1 : 0.45
          }

          PlainText {
            id: favNote
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, favRow.width * 0.42)
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            text: root.favoriteNote(favRow.modelData)
            color: favRow.usable ? root.fg : Commons.Color.urgent
            opacity: favRow.usable ? 0.45 : 0.7
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: favMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: root.pendingFavorite < 0
            cursorShape: Qt.PointingHandCursor
            onClicked: root.favoriteClicked(favRow.modelData)
          }
        }
      }
    }
  }

  Component {
    id: tvSection

    Column {
      spacing: Style.space(8)

      Button {
        readonly property bool onTv: root.current("source") === "tv"
        width: parent.width
        bordered: true
        iconText: onTv ? root.glyphMusic : root.glyphTv
        text: onTv ? strings.t("switchToMusic") : strings.t("switchToTv")
        foreground: root.fg
        accent: root.accent
        onClicked: {
          root.override("source", onTv ? "queue" : "tv")
          root.action(onTv ? "music" : "tv")
        }
      }

      Toggle {
        width: parent.width
        label: strings.t("nightSound")
        description: strings.t("nightSoundDetail")
        checked: root.current("nightMode") === true
        foreground: root.fg
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.toggleSetting("nightMode", "night")
      }

      Toggle {
        visible: !!root.group && root.group.speech !== null
        width: parent.width
        label: strings.t("speech")
        description: strings.t("speechDetail")
        checked: root.current("speech") === true
        foreground: root.fg
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.toggleSetting("speech", "speech")
      }
    }
  }

  Component {
    id: pcSection

    Column {
      spacing: Style.space(6)

      PlainText {
        width: parent.width
        wrapMode: Text.WordWrap
        text: root.pcAudio.apps.length === 0 ? strings.t("noApps") : strings.t("pcHint").arg(root.pcAudio.sink)
        opacity: 0.6
        font.pixelSize: Style.font.bodySmall
      }

      Repeater {
        model: root.pcAudio.apps

        delegate: Toggle {
          required property var modelData
          width: parent.width
          label: modelData.name
          description: root.appOnSonos(modelData)
            ? strings.t("appOnSonos").arg(root.pcAudio.sink)
            : strings.t("appOnPc")
          checked: root.appOnSonos(modelData)
          foreground: root.fg
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.sendApp(modelData.name, !root.appOnSonos(modelData))
        }
      }
    }
  }

  // ---------- local components ----------

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }
}
