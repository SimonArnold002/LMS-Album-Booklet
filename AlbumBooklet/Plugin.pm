package Plugins::AlbumBooklet::Plugin;

# Album Booklet — adds a "View Booklet" entry to Material's Now Playing "…" menu that
# opens a PDF booklet found in the currently-playing album's folder (the digital booklet
# that ships with many hi-res / Bandcamp downloads).
#
# Mechanism (two halves):
#   1. A Material custom action written to the shared actions.json in the *track* category
#      only — that category is consumed solely by Material's Now Playing screen
#      (nowplaying-page.js: getCustomActions("track")), so the entry appears there and
#      nowhere else. It carries the player id as $ID (the Now Playing item exposes no
#      album_id), pointing at our HTTP endpoint.
#   2. A raw HTTP handler (/albumbooklet/booklet?player=<id>) resolves that player's
#      currently-playing track -> its file path -> the album folder -> a *.pdf, and streams
#      it back inline. Technique mirrors the MusicArtistInfo (MAI) plugin's LocalFile.pm:
#      Slim::Utils::Misc::pathFromFileURL + Slim::Web::HTTP::sendStreamingFile(..,'noAttachment').
#
# open_mode pref chooses how Material opens the URL: 'iframe' (in-app dialog) or 'weblink'
# (new browser tab). Both are stock Material custom-action fields (customactions.js).

use strict;

use File::Basename qw(dirname basename);
use File::Path ();
use File::Spec ();
use Encode ();
use URI::Escape qw(uri_escape_utf8);
use HTTP::Status qw(RC_OK RC_NOT_FOUND);
use JSON::XS ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::PluginManager;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Misc;
use Slim::Music::Info;
use Slim::Player::Client;
use Slim::Web::Pages;
use Slim::Web::HTTP;

my $JSON = JSON::XS->new->utf8->canonical->pretty;

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.albumbooklet',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_ALBUMBOOKLET',
});

my $prefs = preferences('plugin.albumbooklet');

$prefs->init({
    material_action => 1,        # write the Now Playing "View Booklet" custom action
    open_mode       => 'iframe', # iframe | weblink
});

# The path our raw HTTP handler answers on. Deliberately NOT under /plugins/ so it can't
# collide with the static-file tree Material serves for this plugin's HTML/images.
use constant URL_PATH => '/albumbooklet/booklet';

sub getDisplayName { 'PLUGIN_ALBUMBOOKLET' }

sub initPlugin {
    my $class = shift;

    if (main::WEBUI) {
        require Plugins::AlbumBooklet::Settings;
        Plugins::AlbumBooklet::Settings->new();
    }

    Slim::Web::Pages->addRawFunction(
        qr{albumbooklet/booklet\b}i,
        \&_serveBooklet,
    );

    return;
}

# Material is loadable once every plugin has initialised.
sub postinitPlugin {
    my $class = shift;
    eval { syncMaterialAction(); 1 }
        or $log->error("AlbumBooklet: postinit sync failed: $@");
    return;
}

# ---------------------------------------------------------------------------
# Material custom action (prefs/material-skin/actions.json)
# ---------------------------------------------------------------------------

# Public entry point (also called by Settings after a save). Writes our action when the
# pref is on and Material is present, otherwise strips it back out.
sub syncMaterialAction {
    if ( $prefs->get('material_action')
      && Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin') ) {
        _writeMaterialAction();
    }
    else {
        _clearMaterialAction();
    }
    return;
}

sub _materialActionsFile {
    my $dir = File::Spec->catdir(Slim::Utils::Prefs::dir(), 'material-skin');
    return File::Spec->catfile($dir, 'actions.json');
}

# Read the shared actions.json into a hashref (empty on missing/corrupt).
sub _readMaterialActions {
    my ($file) = @_;
    my $data = {};
    if (-e $file) {
        local $/;
        if (open my $fh, '<:raw', $file) {
            my $raw = <$fh>;
            close $fh;
            $data = eval { JSON::XS->new->utf8->decode($raw) } || {};
            $data = {} unless ref $data eq 'HASH';
        }
    }
    return $data;
}

# Write atomically: actions.json is SHARED with Material and every other plugin/user
# custom action, so a truncated write would corrupt all of them. Temp file + rename.
sub _writeMaterialActionsFile {
    my ($file, $data) = @_;
    my $tmp = "$file.tmp.$$";
    open my $fh, '>:raw', $tmp or die "open $tmp: $!";
    print $fh $JSON->encode($data) or do { close $fh; unlink $tmp; die "write $tmp: $!" };
    close $fh                      or do {            unlink $tmp; die "close $tmp: $!" };
    rename($tmp, $file)            or do {            unlink $tmp; die "rename $tmp -> $file: $!" };
    return;
}

# Our entry is identified by its URL pointing at our endpoint, in either open mode — so a
# strip pass finds it whichever field (iframe/weblink) a previous version wrote.
sub _isOurAction {
    my ($e) = @_;
    return 0 unless ref $e eq 'HASH';
    for my $k (qw(iframe weblink)) {
        return 1 if defined $e->{$k} && $e->{$k} =~ m{albumbooklet/booklet};
    }
    return 0;
}

sub _writeMaterialAction {
    my $file = _materialActionsFile();
    my $dir  = File::Spec->catdir(Slim::Utils::Prefs::dir(), 'material-skin');
    File::Path::make_path($dir) unless -d $dir;

    my $data = _readMaterialActions($file);

    # Strip any prior entry of ours from every category first (idempotent re-writes,
    # and clears a stale entry if open_mode changed field).
    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY';
        $data->{$cat} = [ grep { !_isOurAction($_) } @{ $data->{$cat} } ];
    }

    my $mode = $prefs->get('open_mode') eq 'weblink' ? 'weblink' : 'iframe';
    # $ID is substituted by Material with the current player id (customactions.js
    # doReplacements). The Now Playing item has no album_id, so the player is the key.
    my $url  = URL_PATH . '?player=$ID';

    push @{ $data->{track} ||= [] }, {
        title  => cstring(undef, 'PLUGIN_ALBUMBOOKLET_VIEW'),
        icon   => 'picture_as_pdf',
        $mode  => $url,
    };

    _writeMaterialActionsFile($file, $data);
    $log->info("AlbumBooklet: wrote Material '$mode' custom action to $file");
    return;
}

# Remove our entry (pref turned off / Material absent). Strip from every category, then
# drop the `track` category only if it is now empty (Listen Later etc. may also write it —
# their entries keep it non-empty and untouched).
sub _clearMaterialAction {
    my $file = _materialActionsFile();
    return unless -e $file;
    my $data = _readMaterialActions($file);

    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY';
        $data->{$cat} = [ grep { !_isOurAction($_) } @{ $data->{$cat} } ];
    }
    delete $data->{track} if ref $data->{track} eq 'ARRAY' && !@{ $data->{track} };

    _writeMaterialActionsFile($file, $data);
    $log->info("AlbumBooklet: cleared Material custom action from $file");
    return;
}

# ---------------------------------------------------------------------------
# HTTP handler — resolve the playing album's folder and serve its PDF booklet
# ---------------------------------------------------------------------------
sub _serveBooklet {
    my ($httpClient, $response) = @_;
    return unless $httpClient->connected;

    my $request = $response->request;
    my %q       = $request->uri->query_form;

    my $client = $q{player} ? Slim::Player::Client::getClient($q{player}) : undef;
    my $folder = $client ? _nowPlayingFolder($client) : undef;

    if (!$folder) {
        return _sendHtml($httpClient, $response,
            _msgPage(cstring(undef, 'PLUGIN_ALBUMBOOKLET_NO_TRACK')));
    }

    my @pdfs = _findPdfs($folder);
    if (!@pdfs) {
        return _sendHtml($httpClient, $response,
            _msgPage(cstring(undef, 'PLUGIN_ALBUMBOOKLET_NONE')));
    }

    # A specific file was requested from the multi-PDF index page. Compare by basename
    # against the folder's own PDF list so a crafted `file` param can't escape the folder.
    if (defined $q{file} && length $q{file}) {
        my ($match) = grep { basename($_) eq $q{file} } @pdfs;
        return _streamFile($httpClient, $response, $match) if $match;
    }

    return _streamFile($httpClient, $response, $pdfs[0]) if @pdfs == 1;

    # Several booklets: show a small index linking each one.
    return _sendHtml($httpClient, $response, _indexPage($q{player}, \@pdfs));
}

# The filesystem folder of the track currently playing on $client, or undef for a remote
# / stopped / streaming track (no local folder to hold a booklet).
sub _nowPlayingFolder {
    my ($client) = @_;
    my $song  = $client->playingSong    or return;
    my $track = $song->currentTrack     or return;
    my $url   = $track->url             or return;
    return unless $url =~ m{^file://}i;
    my $path = Slim::Utils::Misc::pathFromFileURL($url) or return;
    return -d $path ? $path : dirname($path);
}

# All *.pdf in a folder (skipping macOS AppleDouble ._ sidecars), full paths, sorted.
sub _findPdfs {
    my ($folder) = @_;
    opendir(my $dh, $folder) or return ();
    my @files = sort grep { !/^\._/ && /\.pdf$/i } readdir($dh);
    closedir($dh);
    return map { File::Spec->catfile($folder, $_) } @files;
}

sub _mimeType {
    my ($path) = @_;
    return $Slim::Music::Info::types{ Slim::Music::Info::typeFromPath($path) }
        || 'application/pdf';
}

sub _streamFile {
    my ($httpClient, $response, $path) = @_;
    if (!$path || !-f $path) {
        return _sendHtml($httpClient, $response,
            _msgPage(cstring(undef, 'PLUGIN_ALBUMBOOKLET_NONE')), RC_NOT_FOUND);
    }
    $response->code(RC_OK);
    # 'noAttachment' => Content-Disposition inline, so the browser renders the PDF in
    # place (in the iframe dialog / tab) instead of downloading it.
    Slim::Web::HTTP::sendStreamingFile(
        $httpClient, $response, _mimeType($path), $path, '', 'noAttachment' );
    return;
}

sub _sendHtml {
    my ($httpClient, $response, $html, $code) = @_;
    my $bytes = Encode::encode_utf8($html);
    $response->code($code || RC_OK);
    $response->content_type('text/html; charset=utf-8');
    $response->header('Connection' => 'close');
    $response->content_ref(\$bytes);
    $httpClient->send_response($response);
    Slim::Web::HTTP::closeHTTPSocket($httpClient);
    return;
}

my $PAGE_CSS = <<'CSS';
<style>
  html,body{margin:0;height:100%;background:#1a1a1a;color:#e0e0e0;
    font-family:Roboto,'Helvetica Neue',Arial,sans-serif;}
  .wrap{display:flex;flex-direction:column;align-items:center;justify-content:center;
    height:100%;text-align:center;padding:2em;box-sizing:border-box;}
  .wrap .icon{font-size:48px;opacity:.5;margin-bottom:.4em;}
  a{color:#c9a84c;text-decoration:none;display:block;padding:.6em 0;font-size:1.1em;}
  a:hover{text-decoration:underline;}
  h3{font-weight:500;margin:.2em 0 1em;}
</style>
CSS

sub _htmlEscape {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g;
    return $s;
}

sub _msgPage {
    my ($msg) = @_;
    my $m = _htmlEscape($msg);
    return "<!doctype html><html><head><meta charset='utf-8'>$PAGE_CSS</head>"
         . "<body><div class='wrap'><div>$m</div></div></body></html>";
}

sub _indexPage {
    my ($player, $pdfs) = @_;
    my $title = _htmlEscape(cstring(undef, 'PLUGIN_ALBUMBOOKLET_CHOOSE'));
    my $links = '';
    for my $p (@$pdfs) {
        my $name = basename($p);
        my $href = URL_PATH . '?player=' . uri_escape_utf8($player)
                 . '&file=' . uri_escape_utf8($name);
        $links .= "<a href='" . _htmlEscape($href) . "'>" . _htmlEscape($name) . "</a>";
    }
    return "<!doctype html><html><head><meta charset='utf-8'>$PAGE_CSS</head>"
         . "<body><div class='wrap'><h3>$title</h3>$links</div></body></html>";
}

1;
