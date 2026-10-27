# Halcyn theme templates

Each `<id>.json` here is one theme, listed in Settings → Theme. The file name must match its `id`.
`test/themes_test.dart` checks every file parses and stays readable (WCAG contrast).

To add a theme, copy `lapis-velvet-evening.json`, give it a new `id`/`name`, change the values and run `flutter test test/themes_test.dart`.

## Fields

- background: base page colour (bottom of the sky gradient); also the scrim colour over blurred covers and the dock tint. backgroundTop: top of the sky gradient.
- surface / surfaceHigh: menus, tooltips, art placeholders, the phone mini bar. outline: dividers, slider track.
- text / textMuted: primary and secondary text (secondary = artists, durations, album names).
- accent: selection, current song title, seek bar, links, "Bit-exact" badge, nav indicator (at 22% alpha). accentLight → accent → accentDeep: the glossy play/pause orb gradient top→bottom; accentDeep also fills "Play" buttons. onAccent: icon/text colour on the orb and on accentDeep.
- warm: the secondary highlight: "Resampled" badge, warnings, hi-res hints.
- glows: 1-4 radial glows painted over the sky gradient. x/y are Flutter Alignment coordinates (-1..1 is the window edge; values beyond push the centre off-screen), radius is a fraction of the shortest side, alpha is the centre opacity.
- glass: frosted panels (dock, mini player panel, search box, signal card). veil colour fades from veilTop to veilBottom alpha; rim = border alpha; gloss = the bright 1 px streak along the top edge (0 = matte); blur = backdrop blur sigma (0 = no blur); dockTint = alpha of `background` laid under the dock glass.
- shape.radius: multiplier on all corner radii (0.35 = sharp/editorial, 1.0 = current, 1.5 = very round/soft).
- cover: Now Playing and mini player background = the album cover blurred by `blur` at `opacity`, under a scrim of `background` at the three alphas top→middle→bottom.
- sheen: alpha of the light streak across big album covers (0 = matte).

## Contrast rules (enforced by the test)

text vs background, backgroundTop and surfaceHigh >= 7; textMuted vs background >= 4.5; accent and warm vs background >= 3; onAccent vs accentDeep >= 4.5 and vs accent >= 3.
