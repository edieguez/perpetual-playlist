# perpetual-playlist

Keeps an mpv playlist alive across restarts: what you were watching, and
exactly where you left off, survives quitting mpv (on purpose or by
accident).

## What it does

- **Persists the playlist.** On quit, on natural end-of-file, and whenever
  you navigate to another item, the full playlist (plus which item to
  resume from) is saved to `~/.local/state/mpv/last_playlist.json`. Finished
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
   ```

## Adding a video

Adding items to the playlist (clipboard paste, the external `mpv-add` CLI,
YouTube playlist-URL expansion) is entirely
[playlist-manager](https://github.com/edieguez/playlist-manager)'s job -
this plugin only persists and resumes what's already there. Install
playlist-manager alongside this plugin and see its README for `mpv-add`
usage and the `input-ipc-server` config it requires.

## Configuration

See `script-opts/perpetual_playlist.conf.template` for all options and
their defaults. Notably `drop_finished_items` (default `no`): finished
items are kept in the saved playlist by default, not deleted; set to `yes`
to have them dropped once fully watched instead.

## Out of scope

Not a playlist manager - it only persists and resumes playback. By
default it never deletes items on its own either (see
`drop_finished_items` above). It has no add-item handling of its own;
adding items, playlist editing/browsing, and playlist-URL expansion are
all playlist-manager's job (see above) - it's a required companion, not
just an optional one, for adding items via `bin/mpv-add`.

## License

MPL-2.0, see [LICENSE](LICENSE).
