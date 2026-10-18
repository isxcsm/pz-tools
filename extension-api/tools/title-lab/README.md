# Title Lab

A page for working on the API's title effects (`text.title`) without the game: it plays a title and its line in each
style, on a game-like scene, and keeps the effects' numbers on sliders. Open `title-lab.html` in a browser (no server,
no build).

## What it draws

- **The styles as the game has them** (`Texts.java` `Styles`, `Looks.java`, `Dust.java`), with their enter, hold and leave,
  the line's delay and trail, and the backdrop, in the game's premultiplied blending with WebGL and the shader the API compiles
  in the game (`Looks.Gl`'s, a copy of this page's):
  - `stamp` 각인: falls and hits, white-hot and cooling, a streak of light and a puff of dust; a gleam passes once over its hold;
    its title is inked as it hits (wet and glossy for 0.6 s, then solid and still, its edges as crisp as the letters were
    drawn) and dries away in blotches as it leaves (its colour lifts, its line weathers away in place).
  - `discovery` 손전등: a torch sways in from the left and lights the title as it passes, then opens over it; it stutters and
    dies down to embers as it leaves.
  - `notice` 무전: comes in as a radio signal tuned in (rows torn sideways, colours apart, grain), hiccups once as it stays,
    and is lost as it leaves, cutting out twice and sinking into the grain.
  - `unveil` 안개 걷힘: drifting mist behind it clears off it, a veil of it drifting on as it stays; as it leaves it sinks back
    into the mist, which then thins away itself.
  - `dust` 종이 연소 (the default): fades in, then burns spot by spot from its corner (a noise map of when each spot burns), a
    ragged glowing edge, ash shards and sparks tumbling on the wind.
  - `bleed` 번짐: drops fall on the title one after another and spread, soaking it in (its line seeps in); a drop runs down
    as it stays; they dry dark and flake away.
  - `sink` 가라앉음: still water shows under it, its mirror swaying in fine streaks; then it sinks into it, faster and faster.
  - `type` 타자: its letters struck one by one at an uneven pace; its paper fed out a line at a time as it leaves.
  - `pulse` 고동: a heart that races and calms, a warm glow flaring with each beat; one more beat, a stillness, a last weak
    beat, and a breath out.
  - `brief` 짧은 소식: a light title for small news, one small line low on the screen
    that slides up, holds 4 s and burns away from a spot at its middle's foot, spreading round so that the letters
    aside burn from their feet up (`sweep` "round", `ROUND_Y`, `ROUND_K`), fast and then slowing over about 3 s
    (`BURN_SHARE`, `EASE`); its ash thrown out as it burns, slowing, then drifting round in the air for its own 3.5 s
    (`ASH_BURST`, `ASH_SWIRL`, `ASH_HOLD`).

  Every style but `brief` (4 s) holds 5 s once all of it is in (the title and its line).
- **The styles before them** (marked 이전), and `leave = "dust"`'s cells as `Dust.java` has them (숯불 셀, with `dustBurn`).

Only the fonts' shapes, shadows and outlines are approximations (the page draws them with the browser's text).

## Using it

- **스타일** picks the style; **색** keeps its colour or takes one of Operation Acorn's tones.
- The timeline slider runs over the whole title; **바로 사라지기** jumps to its leave; **속도** slows it down.
- **확대** zooms on the title. **배경 이미지** takes a screenshot of the game as the scene.
- **프리셋** keeps a style with its numbers. Saved ones go to the browser's storage; where that is blocked (some
  embedded viewers), **현재 상태 저장** puts the values in the box below, to be added to `BUILT_IN` in the page.
- **Java 상수 만들기** writes the dust's numbers as `Dust.java` constants.

## Taking a change into the game

A change made here goes into the API with the same numbers: the constants in `Looks.java` (and `Dust.java`), the shader's
source in `Looks.Gl` (this page's, its picture read through `pic()`), the styles in `Texts.java`; with `LooksTest`'s numbers
(the page's functions run in node for the same inputs) and `docs/design.md`. The page and the game then look alike.
