# Album Booklet — LMS Plugin

Adds a **View Booklet** entry to [Material Skin](https://github.com/CDrummond/lms-material)'s
**Now Playing** menu. When a track from your local library is playing, it looks in that
album's folder for a PDF booklet (the digital booklet that ships with many hi‑res and
Bandcamp downloads) and opens it — either inside an in‑app dialog or in a new browser tab.

## Features

- **One entry, right where you want it** — sits in the Now Playing "…" menu only, nowhere
  else (it uses Material's `track` custom‑action category, which only the Now Playing
  screen reads).
- **No extra software** — no ImageMagick / Ghostscript / indexing. The booklet is found by
  looking in the folder of the track currently playing, and served by the plugin itself.
- **In‑app or new tab** — choose whether the PDF opens in a Material dialog (iframe) or a
  new browser tab (weblink) in Settings.
- **Several booklets?** If the folder has more than one PDF you get a small chooser.

## How it works

1. The plugin writes a Material **custom action** into the shared `actions.json`
   (`prefs/material-skin/actions.json`) in the `track` category. It carries the current
   **player id** (`$ID`) — the Now Playing item exposes no album id — pointing at the
   plugin's own HTTP endpoint.
2. When you tap it, Material opens `/albumbooklet/booklet?player=<id>`. A raw HTTP handler
   resolves that player's currently‑playing track → its file path → the album folder →
   the first `*.pdf`, and streams it back inline (`Content-Disposition: inline`, so the
   browser renders it rather than downloading).

The file‑serving technique mirrors the excellent
[MusicArtistInfo](https://github.com/michaelherger/MusicArtistInfo) plugin's `LocalFile.pm`
(`pathFromFileURL` + `sendStreamingFile … 'noAttachment'`); this plugin is self‑contained
and does not require MusicArtistInfo to be installed.

## Requirements

- Lyrion Music Server 9.0+
- Material Skin **6.4.3+** (the `iframe`/`weblink` custom‑action mechanism)
- Booklets are read from **local library** folders only (a streaming track has no folder).

## Settings

- **Show "View Booklet" on Now Playing** — write / remove the custom action.
- **Open booklet in** — In‑app dialog (iframe) or New browser tab.

> After changing either setting, **hard‑refresh Material once** — it caches
> `customactions.json` when the app loads.

## Notes

- The entry appears whenever a track is playing; if the album folder has no PDF, it shows a
  short "no booklet found" message rather than hiding itself (a Material custom action is a
  static, global definition and can't self‑hide per album).
- A real *button* on the Now Playing screen isn't possible without patching Material, so the
  supported route is this top‑level "…" menu entry.
