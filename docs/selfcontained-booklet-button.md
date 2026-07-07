# Self-contained "Booklet" button for Now Playing (no plugin required)

This shows how to add a **Booklet** button to Material Skin's Now Playing screen that opens a
PDF found in the currently-playing album's folder — **without** installing the Album Booklet
plugin. Everything below is a modification of your **own Material Skin install**.

## Why two pieces are needed

A Now Playing button is browser JavaScript. Browser JS **cannot read the server's filesystem**,
so it can't find or open a PDF sitting in an album folder on its own. You need a tiny
server-side URL that: looks at what the player is playing, finds a `*.pdf` in that album's
folder, and streams it back. So this example has two parts:

1. **Server side** — a small raw HTTP handler added to `MaterialSkin/Plugin.pm`.
2. **Client side** — a button added to Material's Now Playing view that opens that URL.

Both live inside Material, so no separate plugin is involved. (Note: editing Material's own
files means your changes revert when Material updates — re-apply them then.)

Files (paths on a typical Linux install):
- `…/Plugins/MaterialSkin/Plugin.pm`
- `…/Plugins/MaterialSkin/HTML/material/html/js/nowplaying-page.js`

---

## Part 1 — server side (`MaterialSkin/Plugin.pm`)

Add these `use` lines near the top of `Plugin.pm` (only add ones not already present):

```perl
use File::Basename qw(dirname);
use File::Spec ();
use Slim::Utils::Misc;
use Slim::Player::Client;
use Slim::Web::Pages;
use Slim::Web::HTTP;
```

Register the endpoint inside `sub initPlugin` (anywhere after `my $class = shift;`):

```perl
    # Self-contained booklet endpoint: /custombooklet?player=<playerid>
    Slim::Web::Pages->addRawFunction(qr{custombooklet\b}i, \&_serveBooklet);
```

Add the handler as a new sub anywhere in the file (e.g. just before the final `1;`):

```perl
# Find and stream the first PDF in the folder of the track currently playing on the
# given player. Self-contained; depends only on core LMS.
sub _serveBooklet {
    my ($httpClient, $response) = @_;
    return unless $httpClient->connected;

    my %q = $response->request->uri->query_form;
    my $client = $q{player} ? Slim::Player::Client::getClient($q{player}) : undef;

    # Resolve the playing track -> its file path -> the album folder.
    my $folder;
    if ( $client && (my $song = $client->playingSong) && (my $track = $song->currentTrack) ) {
        my $url = $track->url;
        if ( $url && $url =~ m{^file://}i ) {
            my $path = Slim::Utils::Misc::pathFromFileURL($url);
            $folder = -d $path ? $path : dirname($path) if $path;
        }
    }

    # First *.pdf in that folder (skip macOS ._ sidecars).
    my @pdfs;
    if ( $folder && opendir(my $dh, $folder) ) {
        @pdfs = sort grep { !/^\._/ && /\.pdf$/i } readdir($dh);
        closedir($dh);
    }

    if (@pdfs) {
        my $path = File::Spec->catfile($folder, $pdfs[0]);
        $response->code(200);
        # 'noAttachment' => Content-Disposition: inline, so the browser renders the PDF
        # (in an iframe or tab) instead of downloading it.
        Slim::Web::HTTP::sendStreamingFile(
            $httpClient, $response, 'application/pdf', $path, '', 'noAttachment' );
        return;
    }

    # No booklet: return a small message page.
    my $html = "<!doctype html><html><body style='font-family:sans-serif;background:#1a1a1a;"
             . "color:#ccc;text-align:center;padding-top:3em'>"
             . "No booklet (PDF) found for the current album.</body></html>";
    $response->code(200);
    $response->content_type('text/html; charset=utf-8');
    $response->header('Connection' => 'close');
    $response->content_ref(\$html);
    $httpClient->send_response($response);
    Slim::Web::HTTP::closeHTTPSocket($httpClient);
    return;
}
```

Restart LMS after editing `Plugin.pm`. Quick test from a terminal (replace the MAC with a
player that is currently playing a local album):

```
curl -sI "http://SERVER:9000/custombooklet?player=aa:bb:cc:dd:ee:ff"
```

Expect `Content-Type: application/pdf` when a booklet is found, or `text/html` otherwise.

---

## Part 2 — client side (`nowplaying-page.js`)

Add a click handler method. Find:

```js
    methods: {
```

and insert right after it:

```js
        openBooklet() {
            let player = this.$store.state.player;
            if (undefined==player) {
                return;
            }
            let url = "/custombooklet?player=" + encodeURIComponent(player.id);
            // Open inside a Material dialog:
            bus.$emit('dlg.open', 'iframe', url, 'Booklet');
            // ...or open in a new browser tab instead — comment the line above and use:
            // window.open(url);
        },
```

Add the button itself. The Now Playing screen has two control layouts; each contains the line
`<v-layout text-xs-center class="np-playback">` wrapped in a `<v-flex xs12>`. Immediately
**before** that `<v-flex xs12>` (in one or both layouts — `class="np-controls"` and
`class="np-controls-wide"`), insert:

```html
    <v-flex xs12 class="np-booklet-btn">
     <v-btn flat icon @click.stop="openBooklet" class="np-std-button" title="Booklet"><v-icon class="media-icon">picture_as_pdf</v-icon></v-btn>
    </v-flex>
```

This renders a centred `picture_as_pdf` icon button above the transport controls. `picture_as_pdf`
is part of Material's bundled icon font, so no image file is needed.

> The template lives inside the minified `material.min.js` on a normal install. If you edit the
> source `nowplaying-page.js` you must rebuild Material (`python3 mkrel.py test`, needs Java 17)
> and install the result. For a one-off, you can instead string-replace the same anchors directly
> in the installed `material.min.js`, but that's brittle across Material versions.

---

## Options / variations

- **New tab instead of in-app dialog** — use `window.open(url)` in `openBooklet` (commented line).
- **Only show the button when something is playing** — add
  `v-if="playerStatus.playlist.count>0"` to the `<v-flex xs12 class="np-booklet-btn">`.
- **Multiple PDFs** — this minimal version serves the first PDF alphabetically. To choose, you'd
  return an HTML index of links from `_serveBooklet` and accept a `&file=<name>` param (validate it
  by basename against the folder's own PDF list so it can't escape the folder).
- **Security** — the handler takes no path from the client (only a player id) and always serves
  from the *playing* track's folder, so there's no path-traversal surface.
