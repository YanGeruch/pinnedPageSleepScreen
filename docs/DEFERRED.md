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
- WP6: README.md:83-118 still presents the mount-rw `/etc/locale.conf` + `timedatectl`
  window as the ONLY way to set locale/timezone, and deploy.sh:74-76 hardcodes a
  `timedatectl set-timezone Europe/Kyiv` re-assert — both now have an in-UI equivalent
  (Settings > Display) that would silently fight a hand-set value. Docs/deploy wiring,
  owned by task #9.
