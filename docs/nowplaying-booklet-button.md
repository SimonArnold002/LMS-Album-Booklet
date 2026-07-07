# Optional Material patch — booklet as a *button* on the Now Playing screen

By default Album Booklet adds **View Booklet** to the Now Playing **"…" menu** (Material's
`track` custom-action category). Material has no plugin hook to add a real *button* to the
Now Playing control area, so making it a button needs a small change to Material itself.

This patch renders the Now Playing **custom actions** (which Material already computes into
`this.customActions = getCustomActions("track", …)`) as a centred row of icon buttons above
the transport controls. It's generic: any plugin's `track` action becomes a button — so with
Listen Later also installed you'd get its *Add* actions as buttons too. To show **only** the
booklet, add the filter shown at the end.

All edits are in one file:
`MaterialSkin/HTML/material/html/js/nowplaying-page.js`

---

## Edit 1 — make `customActions` reactive (declare it in `data()`)

`customActions` is assigned in a `bus.$on('customActions', …)` handler but never declared in
`data()`, so Vue won't react to it in a template. Declare it.

Find:

```js
        return { coverUrl:DEFAULT_COVER,
```

Change to:

```js
        return { coverUrl:DEFAULT_COVER,
                 customActions: undefined,
```

## Edit 2 — add a click handler method

Find the start of the methods block:

```js
    methods: {
```

Insert immediately after it:

```js
        npCustomActionBtn(action) {
            let cmd = performCustomAction(action, this.$store.state.player, this.playerStatus.current);
            if (undefined!=cmd) {
                // lmsbrowse-style actions return a command to drill into; ours (iframe/weblink)
                // act directly and return undefined.
                bus.$emit('browse', cmd.command, cmd.params, action.title, 'now-playing');
                bus.$emit('npclose');
            }
        },
```

## Edit 3 — render the buttons (both control layouts)

The template has **two** playback-control blocks: the standard one (`class="np-controls"`)
and the wide/landscape one (`class="np-controls-wide"`). Each contains the line:

```html
     <v-layout text-xs-center class="np-playback">
```

wrapped in a `<v-flex xs12>`. Immediately **before** each `<v-flex xs12>` that wraps that
`np-playback` layout, insert this sibling row (match the surrounding indentation):

```html
    <v-flex xs12 v-if="customActions && customActions.length>0 && playerStatus.playlist.count>0" class="np-custom-actions">
     <v-btn v-for="(action, aidx) in customActions" :key="'nca'+aidx" flat icon @click.stop="npCustomActionBtn(action)" class="np-std-button" :title="action.title"><v-icon v-if="action.icon" class="media-icon">{{action.icon}}</v-icon><img v-else-if="action.svg" class="svg-img media-icon" :src="action.svg | svgIcon(darkUi)"></img></v-btn>
    </v-flex>
```

Doing it in both blocks makes the button appear in every Now Playing layout; if you only use
one layout you can patch just that block.

## Optional — booklet button only

To show *only* Album Booklet's button (skip other plugins' `track` actions), change the
`v-for` to filter on our icon:

```html
     <v-btn v-for="(action, aidx) in customActions" v-if="action.icon=='picture_as_pdf'" :key="'nca'+aidx" ...>
```

## Optional CSS

`np-controls` is already `text-xs-center`, so the buttons centre. For a little breathing room,
add to `MaterialSkin/HTML/material/html/css/…` (or any loaded stylesheet):

```css
.np-custom-actions { margin-top: 4px; margin-bottom: 4px; }
```

---

## Building / installing the patched Material

The template lives inside the **minified** `material.min.js` on a normal install, so edit the
**source** and rebuild, rather than hand-editing the bundle:

1. Work in a Material source tree (e.g. `test-artifacts/lms-material`).
2. Apply the three edits above to `…/html/js/nowplaying-page.js`.
3. Build: `python3 mkrel.py test` → `lms-material-test.zip` (needs **Java 17** + python
   `requests`; CSS minify is pure-Python).
4. Install the resulting `MaterialSkin/` over the box's copy, `chown squeezeboxserver:nogroup`,
   restart LMS, and test in an **incognito** window (Material caches its bundle at app start).

Verify the build carries the change:
`unzip -p lms-material-test.zip HTML/material/html/js/material.min.js | grep -c npCustomActionBtn`

> A patched Material reverts on the next Material update — you'd re-apply then. This is why the
> plugin ships the menu entry (works on stock Material); the button is an optional extra.

*(Quick-and-dirty alternative: string-replace the same anchors directly in the installed
`material.min.js`. It works but is brittle across Material versions — the source+rebuild route
is the maintainable one.)*
