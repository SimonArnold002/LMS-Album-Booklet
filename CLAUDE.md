# Album Booklet — LMS Plugin

## Project Overview
A small, self-contained plugin for Lyrion Music Server (LMS) that adds a **View Booklet**
entry to Material Skin's **Now Playing** "…" menu. When a **local library** track is
playing, it looks in that album's folder for a **PDF booklet** (the digital booklet many
hi-res / Bandcamp downloads ship with) and opens it — either in an in-app Material dialog
(iframe) or a new browser tab (weblink). Targets LMS 9.x, Material Skin 6.4.3+. No extra
server software (no Ghostscript / ImageMagick / indexing).

## Server Details (shared DietPi box — same as the sibling plugins)
- **LMS Server**: 192.168.1.234:9000 (test via hostname `http://plex:9000` — works on/off network)
- **OS**: DietPi (Debian Bookworm); **Service**: `lyrionmusicserver`
- **Plugin location (manual install)**: `/var/lib/squeezeboxserver/Plugins/AlbumBooklet/`
- **Log**: `/var/log/squeezeboxserver/server.log` (HTTP: `curl -s http://plex:9000/log.txt`)
- **Material actions.json**: `<prefs dir>/material-skin/actions.json`
  (served at `/material/customactions.json`)
- Known player MAC (for JSON-RPC menu queries): `dc:a6:32:77:ea:e0`

## Testing WITHOUT SSH (important — never ssh/scp; give Simon bare commands)
Simon installs the zip MANUALLY and pastes logs; diagnose over HTTP.
- **Log**: `curl -s http://plex:9000/log.txt`
- **JSON-RPC**: `POST http://plex:9000/jsonrpc.js`, body
  `{"id":1,"method":"slim.request","params":["<playerMAC>",[<cmd>...]]}` (menu queries need a real player MAC).
- **The booklet endpoint is a browser URL, not JSON-RPC** — test it directly:
  `curl -sI "http://plex:9000/albumbooklet/booklet?player=<mac>"` (expect `Content-Type: application/pdf`
  when a local album with a PDF is playing, or `text/html` for the no-booklet / no-track message page).
- Confirm the custom action was written: `curl -s http://plex:9000/material/customactions.json`
  → look for our entry under the **`track`** key (its `iframe`/`weblink` value contains `albumbooklet/booklet`).

## Install Commands
```bash
sudo rm -rf /var/lib/squeezeboxserver/Plugins/AlbumBooklet
sudo unzip -o AlbumBooklet.zip -d /var/lib/squeezeboxserver/Plugins/
sudo chown -R squeezeboxserver:nogroup /var/lib/squeezeboxserver/Plugins/AlbumBooklet
sudo systemctl restart lyrionmusicserver
```
Ownership must be `squeezeboxserver:nogroup`; the zip extracts directly as `AlbumBooklet/`
(no extra `Plugins/` wrapper). **After install/settings change, hard-refresh Material once**
(it caches `customactions.json` at app load).

## File Structure
```
AlbumBooklet/
├── Plugin.pm      # writes the Material custom action; registers the raw HTTP handler that serves the PDF
├── Settings.pm    # Slim::Web::Settings: material_action toggle + open_mode (iframe|weblink)
├── strings.txt    # PLUGIN_ALBUMBOOKLET_* strings (EN)
├── install.xml    # <extension> singular; icon = AlbumBookletIcon_svg.png; optionsURL
└── HTML/EN/plugins/AlbumBooklet/
    ├── settings.html
    └── html/images/AlbumBookletIcon.{svg,_svg.png,.png}   # #000 SVG for Material recolour + PNG fallbacks
```
Repo root also has `repo.xml`, `README.md`, `AlbumBooklet.zip`.

## How it works (two halves)
1. **Material custom action** (`Plugin.pm::_writeMaterialAction`) written to the shared
   `actions.json` in the **`track` category ONLY**. That category is consumed solely by
   Material's Now Playing screen (`nowplaying-page.js` → `getCustomActions("track")`), so the
   entry appears there and nowhere else — the queue uses `queue-track`, browse lists
   `album-track`/`playlist-track`, streaming `online-track`. (Verified against the sibling
   Listen Later plugin's 0.1.62–0.1.64 notes.)
   - The action's open field is `iframe` **or** `weblink` per the `open_mode` pref — both are
     stock Material custom-action fields (`customactions.js::doCustomAction`: `iframe` →
     `bus.$emit('dlg.open','iframe',url,title)`, `weblink` → `window.open(url)`).
   - The URL is `/albumbooklet/booklet?player=$ID`. **`$ID` = the current player id**, NOT
     `$ALBUMID` — the Now Playing item exposes `album`/`artist`/`title` but **no `album_id`
     and no favurl** (Listen Later 0.1.64), so the player is the only usable key. `$ID` is
     substituted by `customactions.js::doReplacements` from `view.$store.state.player.id`.
2. **Raw HTTP handler** (`Plugin.pm::_serveBooklet`, registered via
   `Slim::Web::Pages->addRawFunction(qr{albumbooklet/booklet\b}i, …)`): resolves the player →
   `$client->playingSong->currentTrack->url` → `Slim::Utils::Misc::pathFromFileURL` → `dirname`
   → globs `*.pdf` → streams the file inline with
   `Slim::Web::HTTP::sendStreamingFile($httpClient,$response,$mime,$path,'','noAttachment')`
   (`noAttachment` = `Content-Disposition: inline`, so the browser renders it, not download).
   - 0 PDFs → a small "no booklet" HTML page; 1 → serve it; >1 → an HTML index linking each by
     basename (`?player=…&file=<name>`). The `file` param is matched **by basename against the
     folder's own PDF list**, so it can't traverse out of the folder.

## Key Technical Decisions
- **Endpoint path is `/albumbooklet/booklet`, deliberately NOT under `/plugins/`** — avoids any
  collision with the static-file tree Material serves for this plugin's `HTML/images`.
  `addRawFunction` is matched before static file lookup. (Same reasoning as MAI's `/mai/localfile/…`.)
- **File-serving technique mirrors MusicArtistInfo (MAI) `LocalFile.pm`** (`pathFromFileURL` +
  `sendStreamingFile … 'noAttachment'`; its `_findTextFiles` globs `pdf|txt|html|nfo|md`). MAI
  already discovers/serves album PDFs but only inside its own info menus (keyed on album/track/
  folder), with no Now-Playing one-tap — hence this plugin. **Self-contained: does NOT require
  MAI installed.** Reference clone was `scratchpad/mai` (github.com/michaelherger/MusicArtistInfo).
- **Custom action can't be conditional on a PDF existing.** `actions.json` is a static global
  definition; the entry shows on every Now Playing track and shows a "no booklet" message when
  the folder has none. (A `registerInfoProvider` route COULD be conditional but lands in
  "… → More", not top-level — rejected per the user wanting it at Now Playing.)
- **No real Now-Playing button possible** without patching Material — the control bar has no
  plugin hook. The `track`-category "…" menu entry is the supported route. Custom actions render
  as menu items in `nowplaying-functions.js` (`view.menu.items.push({… act:NP_CUSTOM+i})`), not buttons.
  - **Optional Material patch to get a real button**: `docs/nowplaying-booklet-button.md`. Three edits
    to `nowplaying-page.js` — declare `customActions` in `data()` (it's set in a `bus.$on('customActions')`
    handler at ~L485 but NOT in `data()`, so it isn't reactive), add an `npCustomActionBtn(action)` method
    (calls `performCustomAction`), and a `<v-btn v-for>` over `customActions` inserted before each
    `<v-layout class="np-playback">` (TWO blocks: `np-controls` + `np-controls-wide`). Generic (renders all
    `track` actions incl. Listen Later's — filter on `action.icon=='picture_as_pdf'` for booklet-only).
    Requires source rebuild via `mkrel.py test` (Java 17); reverts on Material updates.
- **Icon**: `AlbumBookletIcon.svg` uses `fill="#000"` (Material `_svg.png` recolour replaces
  literal `#000`); PNGs generated qlmanage→Pillow (no cairo on this Mac — the documented sibling
  path): luminance→alpha, trim, centre on square with 8% pad, 256². `picture_as_pdf` (the custom-
  action `icon`) is confirmed present in Material's bundled `MaterialIcons.ttf` (fontTools GSUB
  ligature check).
- **actions.json is SHARED** — write atomically (temp + rename); on every write strip only OUR
  entry first (identified by URL containing `albumbooklet/booklet`, in either open field) so
  re-writes/open_mode changes are idempotent and other plugins' entries (incl. Listen Later's own
  `track` entries) are never touched. `_clearMaterialAction` deletes the `track` key only if it is
  empty after stripping ours.

## Prefs Namespace
`plugin.albumbooklet` — `material_action` (write the action, default on), `open_mode`
(`iframe`|`weblink`, default `iframe`). Settings save re-runs `syncMaterialAction` so the change
lands immediately (then hard-refresh Material for the cache).

## Version History
- **0.1.0** — Initial build: Now Playing "View Booklet" Material custom action (`track` category,
  keyed on `$ID`) + raw HTTP handler serving the playing album's folder PDF inline;
  iframe/weblink toggle; multi-PDF chooser; no-booklet / no-local-track message pages.

## Related sibling plugins (same workspace, same author/box)
- **LMS-Listen-to-Later** (`ListenLater`) — the reference for Material custom-action wiring
  (`actions.json` categories, the `$SERVICE`/`$ALBUMID` variable map, `track` = Now Playing only,
  the `$ID`/no-album_id Now-Playing finding at 0.1.64).
- **LMS-ListenBrainz-New-Releases**, **LMS-NowPlayingDisplay**, **lms-nowplayingshare**,
  **LMS-Eversolo-Screen-Control**.
