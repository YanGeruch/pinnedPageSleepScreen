# Touch selection for the lasso — specification and handoff

**This document is complete on its own.** You do not need any other research notes.
Everything known about the feature is written here.

**You do not need to inspect or analyse the xochitl program file.** All the facts you
need are already listed below, including the exact place to change and the exact bytes.
Checking your work is a simple byte comparison, not an investigation.

---

## 1. The goal

On the reMarkable Paper Pro Move, the lasso tool selects a stroke **only if the lasso
surrounds the whole stroke**. If part of the stroke sticks out, the stroke is not
selected.

The user wants the lasso to select the **whole stroke** when the lasso **touches or
crosses** it. Touching must be enough.

Two possible versions:

- **Version 1 (simple).** Change the lasso. Touch selection becomes the only behaviour.
- **Version 2 (the user's ideal).** Add a second selection tool. Keep the old behaviour
  too, and let the user switch between them.

Version 1 is a very small change. Version 2 is a larger piece of work, though less large
than it first appeared — see §8 and §9.

---

## 2. How selection works today

The app has two layers.

- **The interface layer** is written in QML. It shows the toolbar, the pen, and the
  selection frame with its handles.
- **The engine** is native code inside the `xochitl` program. It holds the ink, and it
  decides which strokes a selection contains.

The interface layer can be changed with `qmldiff` mods (`.qmd` files). The engine cannot.

### The steps of one lasso selection

| Step | Layer | What happens |
|---|---|---|
| 1 | Interface | The toolbar sets the active tool to `Line.SelectionTool`. |
| 2 | Engine | The pen handler collects the pen movement into a stroke object. |
| 3 | Interface | `DeviceSceneView.qml:690` receives the finished stroke. |
| 4 | Interface | `DeviceSceneView.qml:719` calls `controller.selectWithLine(stroke, textMode)`. |
| 5 | Engine | The lasso outline becomes a region. **A mode value is set to 0 here.** |
| 6 | Engine | The engine checks every stroke on the layer against that region. |
| 7 | Engine | **The mode value chooses the rule** used for the check. See §4. |
| 8 | Engine | The engine reports the result with the signal `areaSelected(layer, sceneRect)`. |
| 9 | Interface | `DeviceSceneView.qml:325` receives it, and line `341` opens the selection frame. |
| 10 | Interface | `SceneSelectionHandler.qml:394` `open()` draws the frame and the preview. |

Steps 1–4 and 8–10 are in QML and can be changed freely. Steps 5–7 are in the engine.

### The interface files

All paths are inside the extracted QML tree. Extract them again with the command in §10.

| File | Its job |
|---|---|
| `qml/device/view/documentview/DeviceSceneView.qml` | The main hub. Stroke handling at `:690-727`. Selection result at `:325-348`. |
| `qml/common/SceneSelectionHandler.qml` | The selection frame: handles, rotation, dragging, the small menu. `open()` at `:394`. |
| `qml/device/view/documentview/PartitionSelectGesture.qml` | The "Select below" gesture. It builds its own region at `:47-52`. |
| `qml/common/SelectionPreview.qml`, `SelectionHandle.qml`, `SelectionContextualMenu.qml` | The visible parts of the frame. |
| `qml/device/view/documentview/DocumentView.qml` | Sets the tool at `:566`. Has a toggle hook at `:849`. |
| `qt/qml/xofm/modules/refine/default/SelectionHelper.qml` | An empty placeholder. See §8. |

The code at `DeviceSceneView.qml:690` looks like this:

```qml
onStrokeCompleted: (stroke) => {
    completedStroke();
    if (stroke.isHighlighter)        { controller.highlightWithLine(stroke, snapMode); }
    else if (stroke.isEraserTool)    { controller.eraseWithLine(stroke); }
    else if (stroke.isSelectionTool) {
        if (stroke.pointCount === 0) { endItemSelection(); return; }
        const bounds = stroke.boundingRect;
        const isShort = Math.max(bounds.width, bounds.height) < 30;
        if (isShort) { /* treated as a tap on an image */ }
        const textMode = root.textMode ? SceneController.AcceptTapGesture
                                       : SceneController.IgnoreTapGesture;
        controller.selectWithLine(stroke, textMode);       // line 719
    }
    else { controller.addDrawingLine(stroke); }
}
```

---

## 3. The two selection rules in the engine

This is the most important fact in this document.

**The engine already contains both rules.** reMarkable wrote them both. Both are present
and working in the shipped app.

| Rule | Meaning | Used by |
|---|---|---|
| **Rule A — surround** | Every point of the stroke must be inside the region. | The lasso, today. |
| **Rule B — touch** | One point inside the region is enough. | Nothing in the shipped app. |

**Rule B is exactly the behaviour the user wants.**

A single `mode` value chooses the rule:

- `mode = 1` → **Rule B** (touch)
- any other value → **Rule A** (surround)

The lasso sets `mode = 0`. That single `0` is the only reason for today's behaviour.

Two more useful facts:

- Rule A does a quick rectangle test first, and skips a stroke early if its rectangle is
  far away. **Rule B does not have this shortcut.** This is the reason for the speed
  question in §7.
- Only one other place in the app sets `mode = 1`. It is a method called
  `addSelectionRect`. **The interface never calls it**, so Rule B is not used anywhere in
  the shipped app today. Nobody's device has ever run Rule B. This means there is **no
  existing evidence about its speed**.

### There are only two rules, and only two mode values

This was checked carefully, because a third rule would have been useful.

- The mode value is **compared once only**, against `1`. There is no test for `2` or any
  other value anywhere in the selection path.
- Only two places in the app ever write the mode, and both write a fixed number: `0` and
  `1`.
- The entry sitting next to the two rules is **not** a third rule. It takes two
  floating-point numbers, so it works on a single point, not on a region.

So the mode behaves as a simple two-way switch. If the underlying type allows more
values, nothing in the app produces or reads them.

### Each kind of item applies the rules in its own way

The two rules are chosen per item, so **strokes and pictures implement them
differently**:

- For a **stroke**, the rules count the points of the stroke.
- For a **picture**, the rules measure covered area instead.

This is why "all the pixels inside the area" describes real behaviour, but it is the
*picture* version of Rule A. It is **not** a third mode value. It is also the reason the
change in §4 affects pictures as well as strokes.

### The mode cannot be set from outside

The mode is not part of any public interface. At each of the two places, it is a plain
fixed number written into a small structure and passed inward. QML cannot set it, and
neither can a mod, without changing the app itself.

Two arguments look as if they might control it, but do not:

- `selectWithLine`'s second argument is the tap-gesture setting
  (`AcceptTapGesture` / `IgnoreTapGesture`).
- `addSelectionRect`'s second argument (`InitalSelection` / `ToggleSelection`) is stored
  in a **different field** of the same structure — the replace-or-add flag. It is not the
  mode.

### "Select below the line" uses the same rule, not a different one

The app has a second way to select. Press and hold a drawn line, and a button offers
**"Select below"**. The installed `selectionStuff` mod adds **"Select above"**
(source: `https://github.com/FouzR/xovi-extensions`, file `3.27/selectionStuff.qmd`).

This looks like it might work on whole areas or on pixels. **It does not.** It uses
exactly the same machinery as the lasso:

1. `PartitionSelectGesture.qml:50` asks for a shape:
   `selectOverlay.getArea(sceneRect.left, sceneRect.right, sceneRect.bottom)`.
   The mod's extra button is the same call with `sceneRect.top` instead of `.bottom`.
2. That returns an ordinary outline — a tall band the width of the page, reaching from
   the line to the top or the bottom of the page.
3. `DeviceSceneView.qml:868` then calls `controller.selectWithLine(stroke)` — **the same
   method the freehand lasso calls**.

So nothing sends pixels anywhere, and there is no separate area mode. It is the same
"is this stroke inside this shape?" question, asked about a large simple band instead of
a hand-drawn loop. It therefore also sets `mode = 0` and uses Rule A today.

**This gives a way to check the whole model, with no changes to the device.** Because
"Select below" uses Rule A, a stroke that **crosses** the line should **not** be
selected today — part of it lies above the band.

- If a crossing stroke is **not** selected → the model in this document is correct.
- If a crossing stroke **is** selected → something in this document is wrong, and it
  should be re-examined before changing anything.

One caution for the speed question in §7: the band produced by "Select below" is a simple
shape, while a hand-drawn lasso is a complicated one. So "Select below" feeling fast tells
you nothing about how a freehand lasso will perform under Rule B.

### No eraser shares this code

It would be natural to assume that an area eraser and the lasso selection share one
"what does this region touch" routine. **They do not.**

There are **two** eraser tools. The toolbar offers both
(`qt/qml/xofm/libs/toolbar/qml/EraserToolModel.qml`):

| Tool | Behaviour |
|---|---|
| `Line.Eraser` | The direct eraser. A wide stroke that removes what it passes over. |
| `Line.EraseSection` | The area eraser. A thin outline that removes what is inside it. |

Both are handled by the **same** interface branch, `DeviceSceneView.qml:697`
(`stroke.isEraserTool` → `controller.eraseWithLine(stroke)`), and `eraseWithLine` runs
its own separate work item that calls a completely different set of functions.

**The strongest argument does not depend on that detail, though.** The check that reads
the mode value is reached from **exactly two places in the whole app**, and both of them
are selection: the lasso, and `addSelectionRect`. So **no eraser of any kind can reach
the mode switch**, whichever tool the user picks.

Therefore the change in §4 **cannot affect erasing**.

How either eraser decides what it removes has not been examined. If that behaviour ever
needs changing, it is separate work, and none of the facts in this document apply to it.

---

## 4. The change

One instruction decides which rule runs. Changing it makes the engine always choose
Rule B.

| Item | Value |
|---|---|
| File | `/usr/bin/xochitl` on the device |
| Position in the file | offset `0x95efe0` |
| Bytes now | `20 13 00 54` |
| Bytes after | `99 00 00 14` |
| Length | 4 bytes. Nothing else changes. |

**What this affects.** The check that reads the mode value is reached from exactly two
places in the whole app. One of them already uses `mode = 1`, so it cannot change. The
other one is the selection path. So this change affects **selection only**. The
**eraser is not affected**, because it does not use this code at all (§3).

"Selection" here means **everything that goes through `selectWithLine`**, which is more
than the freehand lasso:

| What the user does | Affected by the change? |
|---|---|
| Draws a freehand lasso | **Yes** |
| Uses "Select below the line" (stock) | **Yes** |
| Uses "Select above the line" (from the `selectionStuff` mod) | **Yes** |
| Uses either eraser | No |
| Anything else in the app | No |

This is intended, and it is consistent: after the change, all three selection gestures
follow the same rule. It should still be written in the release notes, because "Select
below" will begin to include strokes that cross the line, which it does not do today.

**Confirmed.** The bytes above were read from the real file and checked. The two rules,
the mode value, and the two callers were all confirmed.

### What exactly is being changed — the value, or the reading of it?

**The reading of it.** This is worth being clear about.

The position `0x95efe0` is **not** the mode value, and it is **not** the place where the
mode value is produced. It is the **single decision instruction** inside the function
that reads the mode.

Before and after:

| | Before | After |
|---|---|---|
| The stored mode | `0` | **still `0` — unchanged** |
| The comparison "is mode equal to 1?" | runs, answer: no | still runs, answer still: no |
| The next instruction | "go to the touch rule **if** the answer was yes" | "go to the touch rule **always**" |

So no stored value is edited anywhere. The lasso still sets `0`, the function still
receives `0`, and the comparison still comes out as "not equal". The only difference is
that the following instruction **stops consulting the answer** and always continues to
the touch rule.

Two consequences worth knowing:

- After the change, the path leading to the surround rule can no longer be reached from
  this function. Nothing else jumps into it, so it simply becomes unused. The surround
  rule itself is left completely intact and is still available to any other part of the
  app that uses it.
- Because the decision no longer depends on the value, the mode becomes irrelevant at
  this point for **both** callers. That is harmless: the other caller was asking for the
  touch rule anyway.

This is also why the change is contained. It does not edit a shared value, and it does
not edit either of the two rules. It edits one decision, in one function, which only the
selection path reaches.

### Why this place, and not one of the other two

There are three places where this could be done. All three were checked.

| | Where | Size | Result |
|---|---|---|---|
| **A** | Make the lasso ask for the touch rule | ~20 bytes, 2 places | Needs a detour. See below. |
| **B** | Make the function ignore the request and use its own fixed number | 4 bytes, 1 place | Works. |
| **C** | Make the function always take the touch path (**chosen**) | 4 bytes, 1 place | Works. |

**Option A** is the neatest in principle, because the shared function would stay
general-purpose: a future caller could still ask for the surround rule. But it does not
fit. The lasso does not "write 0" in an instruction that can be edited — one single
instruction clears the shape, the mode and the flag together, and every neighbouring slot
is already in use. Adding a "write 1" needs a jump out to spare space and a jump back.
That is the only option that changes the flow of the program, and it is five times the
size.

**Option B** would replace the reading instruction with a fixed number:

```
position 0x95efd4 :   02 0b 40 b9   ->   22 00 80 52
```

This works. The value in memory still stays `0`; only the number the function works with
changes. It was confirmed that this number is used **only** for the comparison and is
replaced immediately afterwards, so nothing else is affected.

**Option C is chosen because it relies on fewer assumptions.** B and C behave
identically, and both are 4 bytes in one place. The difference is what they depend on:

- **B is only correct if that position really is the mode.** That depends on reading a
  data layout correctly. The reading is believed right, but it is an interpretation.
- **C does not care** what the number means, where it came from, or how the data is
  arranged. It only requires that the path being taken leads to the touch rule, and that
  was confirmed by following the path and reading the rule itself.

So if the data layout had been misread, B could quietly do the wrong thing, while C would
still be correct.

**A note for Version 2 (§8).** Making the program read a value *you* supply sounds
attractive for a switch, but it does not fit either: it needs at least two instructions
and there is room for one. The practical way to get a switch is to keep change C and have
a small extension **rewrite those same 4 bytes in memory** when the user flips the
setting. That needs no spare space and no detour.

**One extra effect.** The mode value is also used for pictures, not only strokes. So a
lasso that touches a picture will select that picture too. This is probably what a user
wants, but it is a change beyond strokes. It belongs in the release notes.

### These values only fit one app version

| Item | Value |
|---|---|
| Build | `20260612085811` |
| md5 of the unchanged file | `21a55592bb027d5ac8977856a5f1b5c4` |
| Size | 23059096 bytes |

If the device has a different build, these numbers do not apply and the change must not
be written. A safe installer checks the build, the md5, **and** that the 4 bytes really
read `20 13 00 54` before writing.

---

## 5. What the interface layer can and cannot do

You may want to build a probe, or write the second tool. This section lists what QML can
reach.

### The stroke object

The stroke that QML receives is a value type called `Line`. This is its **whole**
surface:

```
float lineLength()          // read-only method

// properties — ALL READ-ONLY
Line::Tool tool
int        pointCount
QRectF     boundingRect
bool       isHighlighter
bool       isSelectionTool
bool       isEraserTool
bool       hasExportedColor
```

Therefore QML **cannot**:

- read the points of a stroke, or of the lasso — there is no points list at all,
- change a stroke,
- create a stroke.

`pointCount` says *how many* points exist. It says nothing about *where* they are. The
most QML can know about a shape is its rectangle.

`Line::Tool` values, in order: `Paintbrush, Pencil, Ballpoint, Marker, Fineliner,
Highlighter, Eraser, SharpPencil, EraseSection, ClearPage, ZoomTool, SelectionTool,
Paintbrushv2, SharpPencilv2, Pencilv2, Ballpointv2, Markerv2, Finelinerv2, Highlighterv2,
SolidPen, ReservedPen, Calligraphy, MaskedEraser, ShadingMarker, Undefined`.
The list is full. **There is no free slot for a new tool type.**

### The controller

`SceneController` is the object QML uses as `controller`. Every method below is callable
from QML.

```
// selection
void  selectWithLine(Line line, SceneController::SelectLineTextMode textMode)
void  selectWithLine(Line line)
void  addSelectionRect(QRect rect, SceneController::LineSelectionMode selectionMode)
QList<QRect> getLineBoundingRectsToBeSelected(QRect area)
QList<QRect> getLineBoundingRectsToBeSelected()
bool  selectImageAtPoint(QPointF scenePosition, int layer)
void  clearSelectedItems()
bool  selectionContainsStroke()
bool  selectionContainsImage()
int   selectionItemCount()

// items — the item list is an opaque handle to QML (see below)
QList<std::shared_ptr<SceneItem>> cloneSelectedItems(int layer, double scaleFactor)
QRectF  getItemBoundingRect(QList<std::shared_ptr<SceneItem>> items)
QPointF getSelectionPastePos(QList<...> items, QRectF sceneBounds, QPointF pos)
void    cloneAddAndSelectItems(int layer, QList<...> items, double scaleFactor, QPointF position)
void    insertItemsAtCursorPosition(QList<...> items)
void    deleteSelectedItems(int layer)
void    moveSelectedItems(int layer, QPointF offset)
void    scaleSelectedItems(int layer, QPointF origin, double xScale, double yScale)
void    rotateSelectedItems(int layer, QPointF origin, double rotation)
void    applyPendingEdit(int layer)
void    cancelPendingEdit()

// strokes and layers
void  addDrawingLine(Line line)
void  eraseWithLine(Line line)
void  highlightWithLine(Line line, SceneController::LineSnapMode snapMode)
void  clearLines()
void  clearLinesInLayer(int layer)
void  setCurrentLayer(int layer)
void  setLayerName(int layer, QString name)
void  setLayerVisible(int layer, bool visible)
bool  isLayerVisible(int layer)
void  addLayer()
void  deleteLayer(int layer)
void  moveLayer(int layer, int newPosition)
void  mergeLayerDown(int layer)
SceneLink linkAt(QPointF scenePosition)

// signals
void  areaSelected(int layer, QRectF sceneRect)
void  selectionCleared()
void  textSelected()
void  penTapRepeated()
void  glyphsSelected(QList<QRectF> selectedAreas, QString text)
void  selectionContainsStrokeChanged()
void  selectionContainsImageChanged()
void  selectionItemCountChanged()

// properties, all read-only
QRectF     boundingRect, itemsBoundingRect
int        currentLayer, selectionItemCount
qsizetype  layerCount
bool       selectionContainsStroke, selectionContainsImage, updating, working
QMatrix4x4 pendingEdit
DocumentWorker* worker
```

### The enums

```
LineSelectionMode  { InitalSelection = 0, ToggleSelection = 1 }   // note their spelling
SelectLineTextMode { AcceptTapGesture = 0, IgnoreTapGesture = 1 }
LineSnapMode       { SnapDisabled = 0, SnapEnabled = 1 }
PasteMode          { KeepStyle = 0, MatchStyle = 1 }
MergeActionMode    { NoMerge = 0, MergeWithPreviousAction = 1 }
MoveMode           { MoveAnchor = 0, KeepAnchor = 1 }
AllowOverscroll    { OverscrollNotAllowed = 0, OverscrollAllowed = 1, OverscrollAlwaysAllowed = 2 }
```

**Two names are misleading. Do not be caught by them.**

- `SelectLineTextMode` has nothing to do with text. It decides whether a very small
  lasso counts as a tap. The QML calls the variable `textMode`, which adds to the
  confusion.
- `LineSelectionMode` means *replace* or *add to* the selection. It does **not** choose
  between surround and touch. The rule switch of §3 is inside the engine and is not
  visible to QML at all.

### Other objects

- `worker` (`DocumentWorker*`) handles jobs, pages and tiles. It has **no stroke list**.
- `tileManager` (`SceneTileManager`) does coordinate maths: `viewToScene`, `sceneToView`,
  `pointInScene`, `rectInScene`, `rectInView`, `renderLineToTiles(Line)`,
  `scrollToMakeSceneRectangleVisible`. Useful for converting positions. It has no
  geometry queries.
- `strokeHandler` (`ScenePenInputHandler`) has the signals `strokeCompleted(Line)`,
  `pasteTriggered`, `gestureStarted`, `gestureMoved`, `gestureEnded`, and the methods
  `setSelectionActive(bool)`, `queryIntermediateState()`, `setShapeDetection`,
  `timeSincePenUp()`, `setTransform`. Enums: `GestureMode { NoGestures,
  WritingToolGestures, SelectionGestures }` and `GestureId { NoGesture,
  DrawAndHoldGesture, TextSelectGesture, PartitionGesture }`.
- `SceneItem` **is not visible to QML at all.** `cloneSelectedItems` gives back a list
  that QML can hold and pass back to `getItemBoundingRect`, `cloneAddAndSelectItems` or
  `insertItemsAtCursorPosition`. QML can do nothing else with it.
- `SelectGestureOverlay` can build a region from three numbers:
  `Line getArea(double left, double right, double yExtent)`, plus `setLine(Line)`,
  `clearLine()`, `getInitialPosition()`, `refreshImage()`. It makes the "everything below
  this line" band used by "Select below". It cannot make any other shape.

---

## 6. Ideas that cannot work, and why

Please do not spend time on these. They fail because the data is not available, not
because they are difficult.

| Idea | Why it fails |
|---|---|
| Change or grow the lasso in QML before it is sent | A `Line` is read-only, cannot be created, and has no points list. |
| Work out the selection in QML from stroke positions | No stroke positions are available anywhere in QML. |
| Use `getLineBoundingRectsToBeSelected` plus `addSelectionRect` | Both are callable, but they only give plain rectangles, and the lasso shape cannot be read. So the test becomes rectangle against rectangle. On dense handwriting this selects strokes the user never touched. It gives a different, worse problem. |
| Read the page file from disk and work it out | Strokes not yet saved are missing from the file, so fresh ink would be ignored. |
| Add a new tool type | The tool list is full (§5). |

One helpful fact: `selectWithLine` does **not** require `isSelectionTool`. The check at
`DeviceSceneView.qml:699` only decides which QML branch runs. The "Select below" gesture
already passes it a region it made itself. So the engine accepts a call from a mod.

---

## 7. The open question: speed

This is the only real unknown.

Rule B has no quick rectangle test. Its region check costs more when the region is
complicated. The lasso region is built from joined outlines, so it can have many parts.
A rectangle region has one part.

So the cost may grow for **every** stroke on the layer, including far-away strokes that
Rule A rejects almost instantly. And because Rule B has never run on any device (§3),
there is no existing evidence either way.

**How to measure it, with no change to the device.** The engine already writes timing and
accept/reject counts to the journal. Turn on this logging category:

```
QT_LOGGING_RULES=rm.ui.scenecontroller.debug=true
```

Do a few lasso selections on a page with dense handwriting and record the durations.
**Do this before the change.** Without a "before" number, an "after" number means
nothing.

**If it turns out to be too slow**, there is a second, larger change that keeps the quick
rectangle test and still gives touch behaviour. It edits two instructions inside Rule A
itself:

| Position | Bytes now | Bytes after |
|---|---|---|
| `0x9a3774` | `and w22, w0, #0xff` | `mov w22, #0` → `16 00 80 52` |
| `0x9a37ac` | the `tbz` branch | `orr w22, w22, w0` → `d6 02 00 2a` |

This is a fallback only. It changes a rule that other parts of the app may share, so its
effect is wider and less certain than the change in §4. Prefer §4 unless speed forces
this.

---

## 8. Version 2: keeping both tools

The change in §4 is all or nothing. It cannot be switched on and off while the app runs.

To offer **both** behaviours, the mode must be decided at run time. That means a small
native extension for `xovi` that changes those same bytes in memory, or supplies the mode
value, according to a setting. This is a bigger job than §4, not a small addition to it.

For the user interface there is already a switch that leads nowhere. You can use it.

- `qt/qml/xofm/modules/refine/default/SelectionHelper.qml` is a placeholder file:

  ```qml
  Item {
      readonly property bool refineMode: false
      visible: refineMode
      function toggleRefineMode() {}
      function enterRefineMode() {}
      function exitRefineMode() {}
  }
  ```

- `DocumentView.qml:849` sends `onRequestToggleSelectionTool` into
  `selectionHelper.toggleRefineMode()`.
- `DeviceSceneView.qml:524-525` raises that from
  `SceneKeyHandlerAction.SelectionToolToggle`.

So a complete toggle path exists already and currently does nothing. A short override of
this file gives you a working switch. A new toolbar button is **not** possible, because
the toolbar model cannot be extended and the tool list is full.

---

## 9. Two ways to deliver the change

There are two ways to apply the 4 bytes. **The second is recommended.**

### Is the calculation imported from a library, so a wrapper could change it?

Partly, but not in a way that helps.

The per-point test **is** a library call: `QRegion::contains`, called out to Qt. It could
be wrapped.

**But wrapping it cannot turn Rule A into Rule B.** Rule A is a loop that gives up as
soon as it finds one point outside. A wrapper sees one point at a time. It cannot know
which stroke the point belongs to, and it cannot look ahead at the points still to come —
and by the time an inside point would appear, the loop has already stopped. A wrapper
that always answered "inside" would select everything on the page.

The part that chooses the rule, and the loop itself, are inside the app and are not
imported. So there is no import to wrap that would produce this behaviour.

### Method 1 — edit the file on the device

Change the 4 bytes in `/usr/bin/xochitl`. This works, but it is **the riskier method**,
because that file is in a protected, read-only area. See §9.1.

### Method 2 — change the 4 bytes in memory, at start-up (recommended)

The app loads at a **fixed address**. So the position given in §4 is exactly where that
instruction sits while the app is running. A small `xovi` extension can therefore change
those 4 bytes in memory when the app starts, and **never touch `/usr/bin/xochitl` at
all**.

| | Method 1: edit the file | Method 2: change it in memory |
|---|---|---|
| Writes to the protected area | Yes | **No** |
| The `mount-rw` problem (§9.1) | Applies | **Avoided completely** |
| After a system update | Silently undone | Simply stops applying, like the other mods |
| To undo | Put the saved copy back | Remove the extension |
| A switch at run time (§8) | Not possible | Natural — change the bytes on demand |

Method 2 also makes Version 2 much easier than it first appeared: the same 4 bytes, written
when the user turns the setting on or off.

**Still to confirm:** the mechanics of the extension itself — making the code area
writable and performing the write. This is ordinary work, and this project already ships
working extensions of this kind, so it is familiar ground rather than something new. It
should be confirmed before the method is considered settled.

## 9.1 Installing by editing the file (Method 1)

**This method is different from every other mod in this project, and it carries more
risk.** All the other mods are files under `/home/root`, plus one systemd drop-in. This
one edits `/usr/bin/xochitl`, which sits on a read-only file system. Method 2 above avoids
everything in this section, which is why it is recommended.

Known facts about that:

- The `mount-rw` helper makes the root file system writable, and it also runs
  `umount -R /etc`. The `-R` also removes the mount that `xovi` uses for its start-up
  hook. `mount-restore` does **not** put that mount back. Afterwards a simple path check
  gives the wrong answer, because the folder is still visible through the overlay. Only
  `/proc/mounts` shows the truth.
- If anything fails between `mount-rw` and `mount-restore`, the root file system is left
  writable.
- A system update **replaces** `/usr/bin/xochitl`. So an update silently removes this
  change. This is different from `.qmd` and `.so` mods, which are simply ignored after an
  update.

A safe sequence therefore looks like this:

1. Copy the unchanged file somewhere safe first, for example
   `cp /usr/bin/xochitl /home/root/xochitl.stock`, and check its md5.
2. Refuse to continue unless build, md5, and the current 4 bytes all match §4.
3. Change the bytes on a copy, then put the finished copy in place. Do not edit the file
   where it lives, so the device never holds a half-written program.
4. Check the new bytes and the new md5.
5. Put the mount state back, then check `/proc/mounts` for the `xovi` mount and start
   `xovi` again if it is missing.

To undo: copy the saved file back and restart.

Method 2 needs none of the above. It writes nothing to the protected area.

Other mods already on the device, for reference: `fastshot.so`, `framebuffer-spy.so`,
`qt-resource-rebuilder.so` (this is `qmldiff`), `qt-command-executor.so` (runs programs,
it cannot inspect objects), `xovi-message-broker.so`, `librarian.so`, `literm.so`,
`rm-pdfium.so`, `rm-shot.so`.

**Other mods will not clash with this work.** `selectionStuff.qmd` changes only
`PartitionSelectGesture.qml`. `linkFromSelection.qmd`, `tocFromSelection.qmd`,
`disableInfiniteScroll.qmd` and `floating.qmd` do touch `DeviceSceneView.qml`, but at
other places. **None of them changes the `onStrokeCompleted` handler**, which is the part
a mod for this feature would use.

---

## 10. Environment

| Item | Detail |
|---|---|
| Device | `root@10.11.99.1` over USB. Reachable. Password is in the project memory notes. |
| Device shell | BusyBox. `head -70` fails, use `head -n 70`. There is no `ldd`. |
| Mac | No `timeout` command. LLVM tools are at `/opt/homebrew/opt/llvm/bin/`. |
| Repository | `/Users/geruch/repos/Configurator/reMarkable` |
| `research/` folder | Not in git. It can be rebuilt with the command below. |
| `rtk` | Wraps shell commands to save tokens. Ignore it. |

Rebuild any interface file by its name:

```bash
cd /Users/geruch/repos/Configurator/reMarkable && python3 tools/extract_qml.py device/xochitl research/device-qml DeviceSceneView.qml
```

The app contains 565 interface files. `research/device-qml/` may hold only some of them.
Extract the ones you need by name; do not assume a file is missing because it is not
there yet.

---

## 11. Decisions still needed from the user

Neither has been answered yet. Do not assume either one.

1. **Version 1 or Version 2?** Version 1 is the 4-byte change and replaces the old
   behaviour. Version 2 keeps both behaviours and needs the extra extension in §8.
   Suggested order: do Version 1 first, let the user feel it, then decide about
   Version 2.
2. **May the device be changed?** The change writes to `/usr/bin/xochitl` (§9). The user
   has been asked and has **not** yet agreed. Do not write to the device before they do.

Two safe steps were offered and are still not done: record the speed of the current
behaviour (§7), and record how the lasso behaves now, for a before-and-after comparison.

---

## 12. Suggested skills

- `mattpocock-skills:prototype` — for the speed probe, and for a first throwaway version.
- `mattpocock-skills:diagnosing-bugs` — if selections come out wrong, or the app restarts
  in a loop.
- `mattpocock-skills:wizard` — the install and undo sequence in §9 has steps only the
  user can approve, so a guided script fits well.
- `mattpocock-skills:grilling` — if the user wants the Version 1 or Version 2 decision
  tested hard before work starts.
