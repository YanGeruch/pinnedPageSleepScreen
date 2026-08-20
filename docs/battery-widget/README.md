# Stock battery widget, as rendered on the Move deep-sleep bar

`move-bar-stock-widget-100pct-charging.png` — cropped from a probe-F framebuffer
capture (2026-08-20, v0.44.3 hunt), 6px margin around the ink bounding box.

- Ink bounding box: **78 x 63 px** (capture coords x 739-816, y 10-72)
- State when measured: 100%, charger attached — the charging BOLT's vertical
  overshoot is included in the 63px height. Body-only height is smaller;
  re-measure discharged if the plate must hug the body.
- Purpose: sizing the opposite-color rectangular outline plate that will sit
  UNDER the widget in the dynamic bar (owner ruling 2026-08-20: plate = widget
  pixel size + a few px of visible outline; the widget itself stays untouched).
