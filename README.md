# Sonos for Omarchy

Control the Sonos speakers on your network from the [Omarchy](https://omarchy.org)
bar, without the Sonos app. Works with any Sonos system: speakers are found
automatically, nothing needs configuring.

## Install

```sh
omarchy plugin add https://github.com/Pieter-Uys/omarchy-sonos --enable
```

It is added to the tray drawer by default; move it with
`omarchy bar move sonos --section right` (or pick a section when asked).
Update later with `omarchy plugin update sonos`.

**Requirements:** Python 3 (standard library only) and, for finding speakers,
`avahi-browse` (the `avahi` package; Omarchy ships it). Your PC must be on the
same network as the speakers. The optional *Play on Sonos* feature needs PipeWire
AirPlay support; see below.

### Set up with Claude

Using [Claude Code](https://claude.com/claude-code) on Omarchy? Copy this prompt
into it and Claude will install the plugin, check it finds your speakers, and
(if you want) set up the PC-audio part, asking before anything that needs sudo.

```text
Set up the Omarchy Sonos plugin from https://github.com/Pieter-Uys/omarchy-sonos
on this machine. Follow these steps in order, tell me what you find at each one,
and ask me before running anything that needs sudo (give me the command to run
myself with the `!` prefix instead). Never edit files in /usr/share/omarchy/.

1. Install and enable it in the bar:
   omarchy plugin add https://github.com/Pieter-Uys/omarchy-sonos --enable --yes
   It goes in the tray drawer by default; ask me if I'd like it somewhere else
   (omarchy bar move sonos --section <left|centerEnd|right|tray>).

2. Check it finds my speakers:
   python3 -I ~/.config/omarchy/plugins/sonos/bin/sonos status
   "ok": true with my rooms listed means it works. If it says "ok": false, check
   that avahi-daemon is running (systemctl status avahi-daemon) and that this PC
   is on the same network as the speakers, then tell me what you found.

3. Ask me whether I also want to send this PC's audio to the Sonos (AirPlay,
   about 2 seconds of delay: fine for music, not for video). If I say no, stop
   here. If yes:
   a. Install PipeWire's AirPlay support (this asks for my password, so give
      it to me to run): omarchy pkg add pipewire-zeroconf
   b. Create ~/.config/pipewire/pipewire.conf.d/50-airplay-sonos.conf with:
      context.modules = [ { name = libpipewire-module-raop-discover args = { } } ]
   c. Restart audio: systemctl --user restart pipewire pipewire-pulse wireplumber
   d. Confirm my Sonos shows up as an output: pactl list short sinks | grep raop_sink
      The Sonos player's IP address is part of that sink name.
   e. If ufw is active (systemctl is-active ufw), AirPlay needs one rule per
      Sonos room that receives audio, using the IP from step d:
      sudo ufw allow from <sonos-ip> proto udp comment 'Sonos AirPlay'
      Suggest I give that speaker a fixed IP in my router so the rule keeps working.
   f. Make sure my default audio output is still my PC speakers or headphones,
      not the Sonos (pactl get-default-sink), so only the apps I choose go to it.

4. Finish by telling me how to use it: click the speaker icon in the bar; the
   Favorites, TV and This PC tabs pick what plays; in This PC, switch on just the
   apps (e.g. Spotify) that should play on the Sonos; the Full/Minimal button in
   the panel header changes the layout.
```

## Features

The panel has two parts: **the player** on top (room, now playing, controls,
volume) and **sources** underneath, meaning where the sound comes from:

| Source | What's in it |
|--------|--------------|
| **Favorites** | Your Sonos Favorites. Each row shows its service (TuneIn, Sonos Radio, Album…) so duplicates are easy to tell apart. Ones that can't play are dimmed with the reason: a folder, an old stream that's offline, or a music service that needs signing in again in the Sonos app (learned the first time it fails). |
| **TV** (home-theatre players: Beam, Arc, Ray, Playbar…) | Switch to the TV input and back to what played before, plus Night Sound and Speech Enhancement. |
| **This PC** (needs AirPlay, see below) | A switch per app playing sound on your PC, to send just that app to the Sonos. While it plays, the player shows the app's own track (e.g. Spotify's title and artist), and the play, pause and skip buttons control the app itself. |

**Full or Minimal**: the button in the panel's header switches layout, and the
choice is saved. *Full* shows the sources as tabs and opens on the one that
matches what's playing. *Minimal* shows each source as a one-line row with a
summary (e.g. "27", "Off", "1 on Sonos") that expands when clicked. It can also
be set in `shell.json` with `"layout": "minimal"`.

With more than one room group, a row of room buttons picks which one to control.
If something can't play, the panel says why under the controls instead of
silently doing nothing.

- **Bar icon** (speaker): click to open the panel, middle-click to play/pause,
  right-click to mute, scroll to change the volume. Dimmed when no speakers are
  found; crossed out when muted.
- **Keyboard** (panel open): Enter plays/pauses, Up/Down change volume,
  Left/Right skip tracks, Esc closes.

## How it works

`bin/sonos` (Python 3, standard library only) speaks the players' local UPnP
control API on port 1400. Players are found with mDNS (`avahi-browse`), falling
back to SSDP, and the addresses are cached in `~/.cache/sonos/players.json`.
It only talks to private IPv4 addresses and never reaches the internet; album
art is loaded only from the player itself. No Sonos account is involved.

The widget polls every 10 seconds while the panel is closed (configurable) and
every 2 seconds while it is open.

```sh
bin/sonos status                 # JSON of every room group
bin/sonos favorites              # JSON of your Sonos Favorites
bin/sonos toggle RINCON_…        # play/pause a group (id from status)
bin/sonos volume RINCON_… 25
```

IPC: `omarchy-shell sonos toggle | playPause | next | previous | volumeUp | volumeDown | mute`.

## Sending PC audio to the Sonos (AirPlay)

Sonos players with AirPlay 2 (Beam, Arc, Era, One, Five…) can be PipeWire outputs:

```sh
omarchy pkg add pipewire-zeroconf
mkdir -p ~/.config/pipewire/pipewire.conf.d
cat > ~/.config/pipewire/pipewire.conf.d/50-airplay-sonos.conf <<'CONF'
context.modules = [ { name = libpipewire-module-raop-discover args = { } } ]
CONF
systemctl --user restart pipewire pipewire-pulse wireplumber
# If ufw is on, let the player's AirPlay timing/control packets back in:
sudo ufw allow from <sonos-ip> proto udp comment 'Sonos AirPlay'
```

The player then shows up as an audio output, and the panel's *Play on Sonos*
section appears. Expect about 2 seconds of latency: fine for music, not for video.
For Spotify, Spotify Connect (pick the room in Spotify's device menu) also works
and doesn't need the PC to stay on.

```sh
bin/sonos apps RINCON_…              # JSON: apps playing, and which go to the Sonos
bin/sonos send RINCON_… Spotify 1    # send one app to the Sonos (0 = back to the PC)
bin/sonos tv RINCON_… / music RINCON_…
```

## Settings

| Key | Default | |
|-----|---------|-|
| `room` | `""` | Room to show when several exist; empty follows whichever is playing |
| `volumeStep` | `2` | Volume change per scroll notch |
| `refreshIntervalSec` | `10` | Background poll interval |
| `layout` | `"full"` | `"full"` (source tabs) or `"minimal"` (collapsed rows); also switchable in the panel |

## Tests

```sh
node --test ~/.config/omarchy/plugins/sonos/tests/
```
