# Historical input diagnosis — 2026-09-22

[Documentation index](README.md) · [User guide](../README.md)

This record concerns one Windows environment on 2026-09-22. It does not establish the behavior of the current build or other environments.

[diagnose-computer-use.ps1](../scripts/diagnose-computer-use.ps1) inspected process tokens without changing privileges, OS settings, or process lifetimes:

| Process | PID at inspection | Integrity | Elevated | UIAccess |
| --- | ---: | --- | ---: | ---: |
| Computer Use input process | 4220 | Medium (`S-1-16-8192`) | 0 | 0 |
| Codex agent | 11944, 20888 | Medium | 0 | 0 |
| Visual Studio | 17184 | High (`S-1-16-12288`) | 1 | 0 |
| PzTools | 20272 | High | 1 | 0 |

Computer Use could capture PzTools, but menu clicks had no visible effect. A separate Calculator test successfully changed its display from `0` to `1`, confirming input delivery to an ordinary-privilege app.

The evidence was consistent with Windows UIPI blocking input from a lower-integrity process into elevated PzTools. Capturing a window does not establish permission to inject input. PzTools' administrator requirement and UAC settings were unchanged.

The investigation referenced [Microsoft's SendInput documentation](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput), a [similar user report](https://github.com/openai/codex/issues/45388), and [Windows elevated-command guidance](https://learn.chatgpt.com/docs/windows/windows-app#run-commands-with-elevated-permissions). These are historical references; the user report is not evidence that a product fix shipped.

To resume that UI validation, first verify the actual input process's integrity and a successful PzTools Settings click. If the helper remains at Medium integrity, a restart alone must not be recorded as a fix. Do not relaunch helpers manually or relax security policy to bypass the boundary.
