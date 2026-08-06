# perpetual-playlist

Keeps an mpv playlist alive across restarts: what you were watching, and
exactly where you left off, survives quitting mpv (on purpose or by
accident).

## What it does

- **Persists the playlist.** On quit, on natural end-of-file, and whenever
  you navigate to another item, the remaining playlist is saved to
  `~/.config/mpv/last_playlist.m3u8`.
- **Resumes from the exact position.** Rides on mpv's native
  `watch_later`/`save-position-on-quit` mechanism, but proactively writes it
  on every item transition (not just on quit), so resuming after a manual
  skip works too, not just after a clean quit.
- **Cold-start items play first.** `mpv <url>` plays `<url>` immediately;
  the previously-saved playlist picks up automatically once it finishes.

## Installation

1. Copy or symlink `scripts/perpetual_playlist.lua` into mpv's `scripts/`
   directory.
2. (Optional) Copy `script-opts/perpetual_playlist.conf.template` to
   `script-opts/perpetual_playlist.conf` to override the defaults.
3. Add these to `mpv.conf` (or an included config file):
   ```
   # Required for the plugin to get a chance to run and resume the saved
   # playlist when mpv is launched with no files.
   idle=yes

   # Required only for bin/mpv-add (external "add a video" dispatcher).
   input-ipc-server=~/.config/mpv/mpv.sock
   ```
4. (Optional) Put `bin/mpv-add` on your `PATH`, or invoke it by full path,
   for adding videos from outside mpv (see below).

## Adding a video while mpv may or may not be running

- **mpv already open:** if you also use
  [playlist-manager](https://github.com/edieguez/playlist-manager), its
  `ctrl+v` binding appends the clipboard URL to the end of the playlist.
  Otherwise, bind a key to `loadfile <url> append-play` yourself.
- **Don't know if mpv is open:** run `bin/mpv-add <url>`. It appends to the
  running instance over mpv's IPC socket if one exists, or launches a fresh
  `mpv <url>` otherwise (which this plugin's cold-start logic then plays
  first). Requires `input-ipc-server` to be set (see Installation) and a
  `nc` with unix-socket (`-U`) support on `PATH`.

## Out of scope

Not a playlist manager - it only adds items and resumes playback, it never
deletes items on its own.

## License

MPL-2.0, see [LICENSE](LICENSE).
