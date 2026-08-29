---
name: surface
description: >-
  Bring a captain-named URL, directory, or file into view in the application appropriate to what it is.
  Use when the captain invokes /surface or asks to open, show, reveal, locate, or bring up a target without choosing the application themselves.
user-invocable: true
metadata:
  internal: true
---

# surface

Bring the named thing in front of the captain with the smallest appropriate action.
Route by the target's actual kind and content, using an extension only as supporting evidence.
Quote every path and never construct a Windows, WSL, drive, or UNC path by hand.

## Resolve the target

1. Treat only an unambiguous `http://` or `https://` value as a URL.
2. For a Windows path, convert it for WSL-side inspection with `wslpath -u -- "$target"`.
3. Keep a WSL path in WSL form for inspection, and convert it for Windows only immediately before opening it with `wslpath -w -- "$path"`.
4. Confirm the converted path exists, then inspect whether it is a directory or regular file and use `file --mime-type -Lb -- "$path"` plus the content when needed to identify the file.
5. If conversion, existence checking, classification, or tool discovery fails, say which target or dependency failed and do not report that it opened.
6. If the target or the requested intent remains ambiguous, ask one concise question instead of guessing.

When Windows interop commands are not on `PATH`, resolve their standard Windows locations through `wslpath` and verify the result is executable:

```sh
explorer_bin=$(command -v explorer.exe 2>/dev/null || wslpath -u -- 'C:\Windows\explorer.exe')
cmd_bin=$(command -v cmd.exe 2>/dev/null || wslpath -u -- 'C:\Windows\System32\cmd.exe')
```

Do not continue with the corresponding Windows route unless `[ -x "$explorer_bin" ]` or `[ -x "$cmd_bin" ]` succeeds.

## Route it

- For a URL, run `chrome-devtools-axi open "$target"` and confirm its returned page URL identifies the requested destination.
- For an HTML file identified from its content or MIME type, run `lavish-axi "$path" --reopen` so an existing session resumes instead of being duplicated.
  After the board opens, load [`../process-event-sources/SKILL.md`](../process-event-sources/SKILL.md) and run `bin/fm-procevent-lavish.sh arm "$path"`.
  Never hold `lavish-axi poll` open in the conversational turn.
  If the board opens but feedback arming fails, report that partial result plainly.
- For a directory, convert it with `windows_path=$(wslpath -w -- "$path")`, then run `"$explorer_bin" "$windows_path"`.
- When the captain asks to locate or reveal a file, convert it with `windows_path=$(wslpath -w -- "$path")`, then run `"$explorer_bin" "/select,$windows_path"`.
- For an office document, PDF, image, or video, convert it with `windows_path=$(wslpath -w -- "$path")`, then run `"$cmd_bin" /d /c start "" "$windows_path"` to use the Windows default application.
- For a text or code file, state its resolved location and show its useful contents or a relevant excerpt in this session.
  Do not launch an editor unless the captain separately asks for one.

`explorer.exe` commonly returns a non-zero status after successfully opening or selecting a target.
Do not use that status alone as evidence of failure, and do not claim visual confirmation that was not observed.
For every route, report the concrete handoff or the concrete reason it could not be made.

Keep this as a routing procedure.
Do not grow it into a file-type registry, plugin system, daemon, or general tool wrapper.
