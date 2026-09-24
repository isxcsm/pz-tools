# Third-party notices

Application and backup-worker builds include a trimmed Eclipse Temurin OpenJDK 25 runtime for the
local JVM Attach helper. Its licenses and notices are included under
`save-bridge/runtime/legal/`; its build information is in `save-bridge/runtime/release`.
OpenJDK is licensed under GPL version 2 with the Classpath Exception, with
additional component notices in that directory. Corresponding Temurin source
and build releases: https://github.com/adoptium/temurin25-binaries/releases
and https://github.com/adoptium/jdk25u. No Project Zomboid classes are distributed
with the bridge.

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
