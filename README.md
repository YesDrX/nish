# nish

Nim shell: oh-my-posh-like powerline prompt, live history search, everything
else via `bash -c` (Linux) / `powershell -Command` (Windows).

## Features

- Colored powerline prompt (`user@host`, `cwd`, `git branch` + dirty `●`,
  exit code, time, `❯`) — `NISH_POWERLINE=0` for ASCII fallback.
- Live history dropdown: shown automatically once you type, no Ctrl-R.
  Nothing is pre-selected, so `Enter` always runs exactly what you typed
  unless you pick an entry. `Up`/`Down` (or `Ctrl-P/N`) move the highlight
  like a visual menu (first step selects the top entry, then `Up` moves up
  and `Down` moves down, wrapping at the ends); the selection is pulled
  into the command line for direct editing (further `Up`/`Down` keeps
  browsing the same list while any edit resumes filtering). `Up`/`Down`
  on an empty line opens recent history. `Tab` completes the
  current token against filesystem paths / PATH commands (repeat `Tab` to
  cycle candidates; case-insensitive, directories get `/` on Linux, `\`
  on Windows — both work in PowerShell), `Esc` dismisses.
- Word jump: `Ctrl+Left/Right`, `Alt+Left/Right`, or `Ctrl+<` / `Ctrl+>`
  move by word (whichever chords your terminal sends; nish decodes C0,
  CSI and modifyOtherKeys forms on POSIX, native console modifiers on
  Windows including `Alt+B/F`). Note `Ctrl+\` shares a byte with `Ctrl+<`
  and acts as word-left instead of quitting the shell; children keep
  normal `Ctrl+\` behavior. On Windows `Ctrl+Z` acts as EOF like `Ctrl+D`.
- Note: commands run via non-interactive `bash -c` (Linux) /
  `powershell -Command` (Windows), so interactive-shell
  aliases (e.g. `ll`) are not available; use the full command instead.
  Override with `NISH_SHELL` (`bash`, `powershell`, `pwsh`, `cmd`).
- 10k ringbuffer history in `~/.nish_history`: loaded once at startup,
  appended during the session (O_APPEND, concurrent-session safe),
  truncated to cap only at startup.
- TUI via [illwill](https://github.com/johnnovak/illwill) (`fullscreen=false`
  mixed mode: `getKey()` input + `TerminalBuffer` composition + custom
  cursor-relative blit so shell scrollback keeps working). On Windows the
  editor uses a native console reader (preserves Ctrl/Alt modifiers) and
  enables VT processing for the ANSI blit, so the same dropdown works in
  Windows Terminal / conhost PowerShell.
- v1 limits: ASCII input, single-line editing, no horizontal scroll past
  terminal width.

## Build (Debian)

```
cd /data01/repositories/nish
nimble install -y   # pulls illwill
nim c -d:release src/nish.nim -o:nish
```

## Build (Windows PowerShell)

```
cd C:\path\to\nish
nimble install -y
nim c -d:release --out:nish.exe src/nish.nim
.\nish.exe
```

Default shell is `bash` on Linux, `powershell` on Windows
(`NISH_SHELL` overrides: `powershell`, `pwsh`, `cmd`, `bash`).

Run tests: `nim c -r tests/t_search.nim`, `nim c -r tests/t_history.nim`.
Batch mode (non-tty stdin) runs lines without the editor.

## Config (`~/.config/nish.yaml`, all keys optional)

```yaml
history_file: ~/.nish_history  # ~ expanded
history_max: 10000             # ringbuffer cap, clamped 100..1000000
suggest_count: 6               # dropdown rows, clamped 1..20
powerline: true                # NISH_POWERLINE=0 env overrides to ASCII
aliases:                       # first-word aliases, win over bash ones
  ll: "ls -l"
```

Missing file, broken YAML, or bad values fall back to defaults per key
(broken file prints one stderr warning, never crashes).

## Aliases

`bash -c` is non-interactive, so nish expands the first word itself
(when the shell is bash):
`~/.bash_aliases` and `~/.bashrc` are scanned per command (always fresh),
`nish.yaml` `aliases:` overlay them. Only the first unquoted word expands;
trailing-space values chain (`alias sudo='sudo '`); cycles stop safely;
`\ll` bypasses expansion, bash-style.
