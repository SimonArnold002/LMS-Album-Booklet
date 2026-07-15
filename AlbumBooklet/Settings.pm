package Plugins::AlbumBooklet::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.albumbooklet');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_ALBUMBOOKLET');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/AlbumBooklet/settings.html');
}

sub prefs {
    return ($prefs, qw(material_action));
}

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;

    if ($params->{saveSettings}) {
        # Persist now so the actions.json rewrite below sees the just-chosen value
        # (SUPER::handler stores it too, but only after it renders the page).
        $prefs->set('material_action', $params->{pref_material_action} ? 1 : 0);

        eval { Plugins::AlbumBooklet::Plugin::syncMaterialAction(); 1 }
            or logger('plugin.albumbooklet')->error("AlbumBooklet: settings sync failed: $@");
    }

    return $class->SUPER::handler($client, $params, $callback, @args);
}

1;
