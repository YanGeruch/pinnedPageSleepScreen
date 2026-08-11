# Deferred findings

One line per finding, appended by WP agents. Findings only — never fixes.

- WP1: unverified — chapter chrome rects come from `mapToItem(DocumentView root)`
  (`src/pinnedPageSleepScreen.qmd:358-372`) while `complement()` clips against the
  sleep window's `root.width/height` (physical portrait, 954x1696 fallback at
  `:1147-1148`). If DocumentView's root is logical-landscape in landscape, the
  chapter holes are computed on swapped axes for exactly the captures WP1 now
  rotates the bar for. Needs a device check (task #10); `complement()` is TRAP-fenced.
- WP7: scripts/package.sh:31 stages only pinnedPageSleepScreen.qmd + SVG into $srcdir —
  hideSidebarGuides.qmd (and any future standalone qmd) needs a staging line before its
  VELBUILD can build. Deploy wiring, owned by task #9.
- WP2: date stamp ("Wed, 6 Aug") is wider than the old numeric form; stamp has no elide/width
  and is left-anchored beside the centered time — check clearance on the narrowest bar. WP3 owns sizing.
- WP3: the plan's directive to multiply the scale into the battery icon factor `f` was NOT followed —
  `f = BattPct.height / battery.implicitHeight` already tracks the scaled text, so a second multiply
  would give 1.35^2 = 1.8225x and overflow the enclosing Item (height stays BattPct.height). Fonts only.
- WP3: `Screen` resolution inside the two sleep-window QML files is unverified on device (stock precedent
  is systemclock/SpinnersContainer.qml:42 under the same bare `import QtQuick`); a try/catch falls back to
  Move sizing, so the worst case is "no upsizing anywhere". Confirm on a 10"/13" panel in task #10.
