# Screen look

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

**Screen look** is an optional colour grade for the game picture, set in **Game extensions**.
It is an extension of its own and off until switched on. Its options are a mood, a strength,
and a switch for seasonal colours.

| Control | What it does |
| --- | --- |
| Mood: Realistic | Slightly less colour, deeper shadows, barely tinted |
| Mood: Vivid | More colour and local contrast, shadows left almost alone |
| Mood: Cinematic | Cool shadows against warm highlights, stronger contrast, soft highlights |
| Strength | 0–100%: how far the chosen mood is applied. It is reduced at night so dark scenes are not crushed |
| Seasonal colours | A small tint and saturation change per season, in daylight and outdoors only |

Night vision is left exactly as the game draws it. A drunk or blurred view is not sharpened.

The preset values are first estimates and have not been tuned against the real game picture.

## What it is not

It is a single pass over the finished frame. It can change colour, contrast and the
sharpness of fine detail. It cannot do what needs several passes or extra buffers (bloom,
ambient occlusion, depth effects), so it will not match a full ReShade preset. ReShade itself
is not used or bundled; someone who wants it can still run it on top.

## How it is applied

The game draws the finished frame through one shader program (`media/shaders/screen.frag`
and what it includes). PZ Tools does not edit that file or any game class.

1. On the game's render thread, the shaders attached to the game's screen program are read
   back from the graphics driver. This is whatever the game compiled: its own shader, or one
   a mod replaced it with.
2. The fragment shader that holds the entry point gets `#define main pzt_base_main` after
   its `#version` line, and a new `main` is appended that calls the original and then adjusts
   the colour it wrote. Nothing else in the text changes. The chosen values are constants in
   that appended text.
3. That shader is compiled and linked into a **second** program together with the game's
   other, untouched shader objects, with every vertex attribute at its original location.
4. The game's shader object is pointed at the new program, the program is filed under its
   number in the game's program register (`ShaderPrograms.registerProgram`, as
   `ShaderProgram.compile` does), and the game's own post-compile steps run
   (`ShaderProgram.onCompileSuccess`, then its compile listeners), so the game looks its
   uniforms up again exactly as it does after compiling a shader itself.

   The shader object's remembered matrices (`ShaderProgram.modelView` and `projection`) are
   also set to zero, as `compile` resets them.

   Both matter for the same reason. Before drawing, the game finds the bound program in the
   register by number and sends it the screen's `ModelViewProjection`
   (`ShaderHelper.setModelViewProjection` → `VertexBufferObject.setModelViewProjection`),
   but only when the matrices differ from the last ones sent to that `ShaderProgram`
   object. The grade reuses the game's object, whose remembered matrices already equal the
   screen's, and the screen's never change. Without both steps the new program never
   receives a projection: the screen quad covers nothing, and the last finished picture
   stays on screen while the game moves on underneath (pausing changed the matrices once,
   which is why the picture jumped then). A number that goes away (a replaced grade, the
   switch back) is taken out of the register again, but only while it is still filed for
   this program.

The original program is kept. Turning the look off, closing the app, leaving the world or
disabling the extension points the game back at it and frees the second program. A change
of mood, strength or season builds a new second program from the original and swaps it in.

The appended code uses `abs()` for its limits rather than `max()`/`clamp()`: the game's
shader declares its own overloads of those two, which hides the built-in ones.

### When it does nothing

Each of these leaves the game's picture as it was. The module reports the fault, the
scheduler turns this extension off (in the game and in the saved preferences), and the
card shows that it could not be started. Other extensions are not affected. Switching it
on again, or changing its options, tries again.

- The shader has no recognisable entry point or colour output, or writes several outputs.
- The driver rejects the extended shader, or the programs do not link.
- The game's uniform lookup throws on the new program (the original is restored first).
- A game update removed one of the classes or members used (`SceneShaderStore.weatherShader`,
  `ShaderProgram.shaderId`, `ShaderPrograms.registerProgram`, `ShaderProgram.modelView`,
  `RenderThread.queueInvokeOnRenderContext`, …). The module is then
  unsupported from the start and never touches the shader.

If the game rebuilds its screen shader (graphics options, shader reload), the look is built
again on top of the new program.

With a mod's screen shader the colour grade still applies. Sharpening and the night and
outdoor conditions are only added when the shader has the game's own inputs (`DIFFUSE`,
`vUV`, `NightValue`, `Exterior`); without them those parts are left out.

## Where it lives

The look is an extension of its own, `pztools.screen-look` (capability `screen.grade.v1`),
delivered as `pztools-screen-look.jar`. It has its own catalogue row, switch,
supported-version rule and **Ignore supported version range** switch, and nothing in it
knows about vehicles. It installs no hook and changes no game class; the module's only
effect on the game is the one shader program described above.

It runs on the same control lease as the vehicle module, in its own slot; see
[several modules on one connection](game-extensions.md#several-modules-on-one-connection).
Turning it on or changing it needs no particular moment in the game and resets nothing.

Its choices are stored under its own entry in
`%LOCALAPPDATA%\PzTools\extensions\settings.json` (`screenLook`: `preset`, `strength`,
`seasonal`). Two values are tuned only in [screen-look.toml](../config/game-extensions/screen-look.toml)
(overrides in `%LOCALAPPDATA%\PzTools\extensions\screen-look.toml`): `clarity_scale` (0–2)
and `seasonal_amount` (0–1). The file cannot set the choices made in the app.

Code: [GradeShader](../src/PzTools.GameExtensions.ScreenLook/java/pztools/extensions/screen/GradeShader.java)
(text only), [GradeParameters](../src/PzTools.GameExtensions.ScreenLook/java/pztools/extensions/screen/GradeParameters.java)
(moods), [ScreenGrade](../src/PzTools.GameExtensions.ScreenLook/java/pztools/extensions/screen/ScreenGrade.java)
(install and restore), [ScreenLookProvider](../src/PzTools.GameExtensions.ScreenLook/java/pztools/extensions/screen/ScreenLookProvider.java)
(the module).
## Verification

Automated, without a game: the text transform, the presets, and install/replace/restore/
failure handling over a scripted driver (`ScreenGradeTest`).

Against the installed game's shader files and the local graphics driver, without starting
the game (a hidden window provides the graphics context; nothing is written):

```text
javac -cp <pztools-extension-runtime.jar>;<pztools-screen-look.jar>;<projectzomboid.jar> -d <out>
    tests/game-extensions-installed/pztools/extensions/screen/VerifyInstalledScreenShader.java
java -cp <out>;<pztools-extension-runtime.jar>;<pztools-screen-look.jar>;<projectzomboid.jar>
    pztools.extensions.screen.VerifyInstalledScreenShader <game directory>
```

It compiles the game's screen shader as the game assembles it, builds every mood and season
on top through the same driver calls the extension uses, checks that every uniform and
vertex attribute survives, and draws a test colour through each.

Not covered by either: the swap inside a running game (the render-thread queue, the game's
uniform lookup on the new program, a game-initiated shader rebuild), and how the moods
actually look. Those need the checks in the [vehicle test guide](e2e-vehicle-drivetrain.md).
