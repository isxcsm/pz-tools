# Third-party notices

PZ Tools itself is released under the MIT License (see `LICENSE`). The components
below are distributed with it, or were adapted for it, under their own terms.

## Libraries distributed with the app

| Component | License | Copyright / source |
| --- | --- | --- |
| Microsoft.Data.Sqlite, System.IO.Hashing | MIT | © Microsoft Corporation. https://github.com/dotnet |
| Windows Community Toolkit (SettingsControls, Extensions, Helpers, Triggers, Common) | MIT | © .NET Foundation and Contributors. https://github.com/CommunityToolkit |
| SQLitePCLRaw (core, provider, bundle, `e_sqlite3`) | Apache-2.0 | Copyright 2014-2024 SourceGear, LLC. https://github.com/ericsink/SQLitePCL.raw |
| SQLite (inside `e_sqlite3.dll`) | Public domain | https://www.sqlite.org/copyright.html |
| Tomlyn | BSD-2-Clause | Copyright (c) 2019-2026, Alexandre Mutel. https://github.com/xoofx/Tomlyn |
| Windows App SDK, WinUI, WebView2 loader | Microsoft Software License Terms | © Microsoft Corporation. https://github.com/microsoft/WindowsAppSDK/blob/main/LICENSE |

License texts: MIT is reproduced several times below.
The Apache License 2.0 is included in full as `licenses/Apache-2.0.txt`.

Tomlyn (BSD 2-Clause):

Copyright (c) 2019-2026, Alexandre Mutel
All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## OpenJDK runtime

Application and backup-worker builds include a trimmed Eclipse Temurin OpenJDK 25 runtime for the
local JVM Attach helper. Its licenses and notices are included under
`save-bridge/runtime/legal/`; its build information is in `save-bridge/runtime/release`.
OpenJDK is licensed under GPL version 2 with the Classpath Exception, with
additional component notices in that directory. Corresponding Temurin source
and build releases: https://github.com/adoptium/temurin25-binaries/releases
and https://github.com/adoptium/jdk25u. No Project Zomboid classes are distributed
with the bridge.

## pzmonitor players.db layout

The Build 42 player blob layout used by `PlayerBlobDurationReader` was adapted
from [pzmonitor's players.db parser](https://github.com/MarioMoura/pzmonitor/blob/main/internal/playersdb/parser.go).

MIT License

Copyright (c) 2026 Mario Moura

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Microsoft Fluent UI System Icons

The Home and game-extension navigation icons use the Home and Apps 24 px color
SVGs from [Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons/tree/a563cf9166f4f91aa617557ed272612b7f0a2f72).
The Home icon's walls and door are recolored gray. The Apps icon is unchanged.

MIT License

Copyright (c) 2020 Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Buy Me a Coffee cup mark

The support button uses the cup geometry from Buy Me a Coffee's official
[button logo SVG](https://cdn.buymeacoffee.com/buttons/bmc-new-btn-logo.svg),
linked through its [brand assets](https://buymeacoffee.com/brand).
The original paths are combined into a native monochrome icon; hover uses
a muted coffee/biscuit tone adapted to the app theme, with a system-color
override in high contrast.
The mark identifies the external support service and remains the property
of its respective owner. No remote widget or runtime asset download is used.

## Project Zomboid world-249 chunk layout

The structural map/corpse reader was adapted from the MIT-licensed pzdataspec
world-249 schema descriptions by cff29546 and checked against the installed game.
No game binaries, proprietary decompiled classes or private saves are included.
Source: https://github.com/cff29546/pzdataspec

MIT License

Copyright (c) 2026 Min Xiang

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
