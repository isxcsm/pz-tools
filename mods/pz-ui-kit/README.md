# PZ UI Kit

A Project Zomboid (Build 42) Lua mod that other mods draw their windows with. It adds nothing to the game by itself.

- **One scale for every screen.** Windows are laid out in design units made for a 16 unit Small font; the kit turns
  them into pixels by the screen's height (with the PZ Extension API's UI fonts) or by the game's font (without).
- **Sharp texts.** With the [PZ Extension API](../../extension-api) installed, texts are drawn in its UI fonts at the
  pixel size the scale asks for (Noto Sans, Korean included); without it, in the game's fonts.
- **Palettes.** Every widget draws in its window's palette (`window.palette`), a table of `{ r, g, b }` colours: `bg`,
  `panel`, `text`, `dim`, `bright`, `value`, `head`, `border`, `warn`, `bad`, `good`, `sel`, `title`, `dark`, `inset`,
  `off`, and `tabStrip`. `PZUIKit.UI.DEFAULT_PALETTE` is used outside a window.
- **Lights.** A thing under the mouse lights up and a click flashes (`UI.hoverLight`, `UI.flash`, `UI.placeLight`),
  followed frame by frame only while they move (`UI.live`).
- **Fades.** A window fades in and out (`UI.fadeIn`, `UI.fadeOut`, `UI.fadeTo`), and steps aside while its player
  works: `UI.aside(window, action)` thins it for as long as the timed action is queued, so the game's progress bar over
  the character shows through, and `UI.stepAside(window, hold)` in the window's update brings it back.
- **Widgets.** `PZUIButton`, `PZUICombo`, `PZUIConfirm` (`UI.confirm`), `PZUIPopMenu` (`UI.menu`: a window's menu at the
  mouse, dim heads over its choices, the one in use marked), `PZUIRichText`, `PZUIRichTip` (a rich-text
  tooltip that follows the mouse), `PZUISubTabs` (with a tooltip per tab), and lists of the game's
  `ISScrollingListBox` with rows drawn in design units (`UI.list`).
- **Text that fits.** `PZUIKit.Text.wrap`, `fitText` and `cutFor` (shared, so they also run on a server and in tests).
- **Typed text.** `PZUITypedText`, a rich text panel that types its text a character at a time (by the timings of
  `PZUIKit.Markup`, the extension API's markup: pauses, speeds, colours) or prints it a row at a time, whole, as a
  teleprinter does (`PZUIKit.Typing.LINE_STEP`), with a blinking cursor; a click brings it to the furthest point seen.
  `PZUIKit.Typing` keeps how far a text has been seen and lays a document's marks out (`## ` heads, `· ` bullets,
  `~ ` dim lines, `> ` the sign-off) for the rich text panel (shared, tested outside the game).

`PZUIKit/42/media/lua/client/PZUIKit/UI.lua` starts with the rules for design units, faces and the scale.

## Using it

Require the mod (`require=PZUIKit` in your `mod.info`) and its files:

```lua
require "PZUIKit/UI"
require "PZUIKit/Button"
local UI = PZUIKit.UI

MyPanel = ISPanel:derive("MyPanel")
function MyPanel:prerender()
    UI.fill(self, 0, 0, self.width, self.height, self.palette.bg)
    UI.text(self, "Hello", 10, 10, self.palette.text)
end
UI.scaled(MyPanel, ISPanel)   -- MyPanel works in design units

-- before a window opens: the scale for the screen and the font now
UI.refreshScale()
```

Mod Lua holds no letters past ASCII (the game reads them as U+FFFD): texts come from translation keys.

## Tests

The kit's tests run in [operation-acorn](../operation-acorn) for now (`tests/unit/trade_faces_test.lua`,
`trade_scale_test.lua` and the windows built on it), whose harness loads the kit from this folder beside it.

## License

MIT.
