# perpetual-playlist

Keeps an mpv playlist alive across restarts: what you were watching, and
exactly where you left off, survives quitting mpv (on purpose or by
accident).

## What it does

- **Persists the playlist.** On quit, on natural end-of-file, and whenever
  you navigate to another item, the full playlist (plus which item to
  resume from) is saved to `~/.config/mpv/last_playlist.json`. Finished
  items are kept, not deleted - set `drop_finished_items=yes` to opt back
  into removing them (see Configuration).
- **Resumes from the exact position.** Rides on mpv's native
  `watch_later`/`save-position-on-quit` mechanism, but proactively writes it
  on every item transition (not just on quit), so resuming after a manual
  skip works too, not just after a clean quit.
- **Cold-start items play first.** `mpv <url>` plays `<url>` immediately -
  it's spliced into the saved playlist at your last-watched spot (pushing
  that item, and everything after it, one slot later) rather than tacked
  onto the very front. Once it finishes, playback carries straight on into
  the item you were actually on and the rest of your history from there;
  already-watched items before it are never replayed.

## Installation

1. Copy or symlink `scripts/perpetual_playlist.lua` into mpv's `scripts/`
   directory.
2. (Optional) Copy `script-opts/perpetual_playlist.conf.template` to
   `script-opts/perpetual_playlist.conf` to override the defaults (see
   Configuration).
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
- **Don't know if mpv is open:** run `bin/mpv-add <url> [url ...]`, or
  `bin/mpv-add -n/--next <url> [url ...]` to insert right after whatever's
  currently playing instead of appending to the end. Either way, items are
  added in the order given, to the running instance over mpv's IPC socket
  if one exists, or launched with a fresh `mpv <url> [url ...]` otherwise
  (which this plugin's cold-start logic then plays in order regardless of
  `-n`/`--next`). Requires `input-ipc-server` to be set (see Installation)
  and a `nc` with unix-socket (`-U`) support on `PATH`.

  `mpv-add` works standalone - `perpetual_playlist.lua` has its own
  `mpv-add-item`/`mpv-add-item-next` handlers (dedup, directory expansion,
  correct multi-item `-n` ordering), so this doesn't require
  playlist-manager to be installed. If playlist-manager *is* also
  installed, it handles the same messages too (its own dedup prevents a
  double-add either way) and adds one extra feature this plugin's own
  handler intentionally doesn't replicate: a YouTube playlist URL added
  via `mpv-add` expands into its individual videos.

## Configuration

See `script-opts/perpetual_playlist.conf.template` for all options and
their defaults. Notably `drop_finished_items` (default `no`): finished
items are kept in the saved playlist by default, not deleted; set to `yes`
to have them dropped once fully watched instead.

## Out of scope

Not a playlist manager - it only adds items and resumes playback. By
default it never deletes items on its own either (see
`drop_finished_items` above). Its own `mpv-add-item`/`mpv-add-item-next`
handlers (see above) exist only so `bin/mpv-add` works without
playlist-manager installed - actual playlist editing/browsing is
playlist-manager's job.

## License

MPL-2.0, see [LICENSE](LICENSE).
