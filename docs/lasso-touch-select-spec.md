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

Version 1 is a very small change. Version 2 is a larger piece of work. See §8.

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
other one is the lasso. So this change affects **the lasso only**. Nothing else in the
app changes behaviour.

**Confirmed.** The bytes above were read from the real file and checked. The two rules,
the mode value, and the two callers were all confirmed.

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

## 9. Installing the change

**This change is different from every other mod in this project, and it carries more
risk.** All the other mods are files under `/home/root`, plus one systemd drop-in. This
one edits `/usr/bin/xochitl`, which sits on a read-only file system.

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
