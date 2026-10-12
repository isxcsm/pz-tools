# Title Lab

A page for working on the API's title effects (`text.title`) without the game: it plays a title and its line in each
style, on a game-like scene, and keeps the effects' numbers on sliders. Open `title-lab.html` in a browser (no server,
no build).

## What it draws

- **The styles as the game has them**: `stamp`, `discovery`, `notice`, `unveil` and `dust`, with the enter, hold and
  leave of `Texts.java` (`Styles`, `draw`), the line's delay and trail, and the backdrop. `dust` is `Dust.java`'s
  arithmetic as it is (cells, seed, wind, the charcoal burn), with the game's premultiplied blending in WebGL.
- **Drafts** (marked 새안) not yet in the game:
  - `stamp` 각인: falls and hits, white-hot and cooling, a streak of light and a puff of dust; a gleam passes once over
    its hold; it weathers away in place (its colour drains, it wears off in pits from its edges).
  - `discovery` 손전등: a torch sways in from the left and lights the title as it passes, then opens over it; it
    stutters and dies down to embers as it leaves.
  - `dust` 종이 연소: burns spot by spot from its corner (a noise map of when each spot burns), a ragged glowing edge,
    ash shards tumbling on the wind.

Only the fonts' shapes, shadows and outlines are approximations (the page draws them with the browser's text).

## Using it

- **스타일** picks the style; **색** keeps its colour or takes one of Operation Acorn's tones.
- The timeline slider runs over the whole title; **바로 사라지기** jumps to its leave; **속도** slows it down.
- **확대** zooms on the title. **배경 이미지** takes a screenshot of the game as the scene.
- **프리셋** keeps a style with its numbers. Saved ones go to the browser's storage; where that is blocked (some
  embedded viewers), **현재 상태 저장** puts the values in the box below, to be added to `BUILT_IN` in the page.
- **Java 상수 만들기** writes the dust's numbers as `Dust.java` constants.

## Taking a draft into the game

A draft is a design: when it is settled, its arithmetic goes into the API (`Texts.java`, `Dust.java`, a shader where
it needs one) as a style or an effect of its own, with its tests and `docs/design.md`; the page keeps the same numbers
so that both look alike.
