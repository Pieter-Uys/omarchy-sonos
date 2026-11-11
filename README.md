# Sonos (pieter.sonos)

Control the Sonos speakers on your network from the Omarchy bar, without the Sonos app.

- **Bar icon** (speaker): click to open the panel, middle-click to play/pause,
  right-click to mute, scroll to change the volume. Dimmed when no speakers are found;
  shows a crossed-out speaker when muted.
- **Panel**: now playing with album art, seek bar, previous / play-pause / next,
  a TV-input button, group volume with mute, and for home-theatre players
  (Beam, Arc, Ray, Playbar…) Night Sound and Speech Enhancement toggles.
  Your Sonos Favorites are listed underneath; click one to play it. If a favorite
  can't play (its music service is signed out on the Sonos, or it's a folder),
  the panel says so instead of silently doing nothing.
- **TV button** toggles: switch to the TV input, then back to whatever played
  before (remembered even when the TV switched the player over by itself).
- **Play on Sonos**: lists the apps playing sound on this PC, each with a switch
  that sends just that app to the Sonos over AirPlay (see below). Spotify can go
  to the Sonos while notifications and the browser stay on your PC speakers;
  WirePlumber remembers the choice per app.
  With more than one room group, a row of room chips picks which one to control.
- **Keyboard** (panel open): Enter plays/pauses, Up/Down change volume,
  Left/Right skip tracks, Esc closes.

## How it works

`bin/sonos` (Python 3, standard library only) speaks the players' local UPnP
control API on port 1400. Players are found with mDNS (`avahi-browse`), falling
back to SSDP, and the addresses are cached in `~/.cache/pieter.sonos/players.json`.
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

IPC: `omarchy-shell pieter.sonos toggle | playPause | next | previous | volumeUp | volumeDown | mute`.

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

## Tests

```sh
node --test ~/.config/omarchy/plugins/pieter.sonos/tests/
```
