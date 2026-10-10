## prompt.nim - oh-my-posh-like powerline prompt.
##
## Returns styled runs using illwill color types; the editor composes them
## into an illwill TerminalBuffer. `visibleLen` is the exact terminal column
## width (ANSI has no place here - colors live in the Run attributes).

import illwill, os, osproc, strutils, times, unicode

type
  Run* = object
    text*: string
    fg*: ForegroundColor
    bg*: BackgroundColor
    bright*: bool

  Prompt* = object
    runs*: seq[Run]
    visibleLen*: int

const PowerSep = "\uE0B0" #  powerline separator (Nerd Font / powerline font)

proc usePowerline*(cfgDefault = true): bool =
  ## Explicit NISH_POWERLINE env wins; otherwise the config file value.
  let e = getEnv("NISH_POWERLINE", "")
  if e != "":
    e != "0"
  else:
    cfgDefault

proc addRun(p: var Prompt, text: string, fg: ForegroundColor,
    bg = bgNone, bright = false) =
  p.runs.add(Run(text: text, fg: fg, bg: bg, bright: bright))
  p.visibleLen += text.runeLen

# --- git segment (cached: at most one probe per 2s per cwd) ---
var
  gGitCacheCwd = ""
  gGitCacheAt = 0.0
  gGitCacheTxt = ""
  gGitCacheDirty = false
  gGitCacheOk = false

proc gitInfo(cwd: string): tuple[ok: bool, txt: string, dirty: bool] =
  let now = epochTime()
  if cwd == gGitCacheCwd and now - gGitCacheAt < 2.0:
    return (gGitCacheOk, gGitCacheTxt, gGitCacheDirty)
  gGitCacheCwd = cwd
  gGitCacheAt = now
  gGitCacheOk = false
  try:
    let (branch, code) = execCmdEx("git rev-parse --abbrev-ref HEAD 2>/dev/null")
    if code == 0:
      let b = branch.strip()
      if b.len > 0:
        gGitCacheOk = true
        gGitCacheTxt = b
        let (st, c2) = execCmdEx("git status --porcelain 2>/dev/null")
        gGitCacheDirty = c2 == 0 and st.strip().len > 0
  except OSError:
    discard
  (gGitCacheOk, gGitCacheTxt, gGitCacheDirty)

proc shortCwd*(): string =
  var d = getCurrentDir()
  let home = getHomeDir()
  if d.startsWith(home):
    d = "~" & d[home.len - 1 .. ^1]
  # keep at most 3 trailing components
  let parts = d.split('/')
  if parts.len > 4:
    d = "…/" & parts[^3 .. ^1].join("/")
  d

proc buildPrompt*(lastExit: int, powerline = true): Prompt =
  result = Prompt(runs: @[], visibleLen: 0)
  let power = powerline
  let user = getEnv("USER", getEnv("USERNAME", "user"))
  var host = getEnv("HOSTNAME", "")
  if host.len == 0:
    try:
      host = execCmdEx("hostname -s 2>/dev/null")[0].strip()
    except OSError:
      discard
    if host.len == 0:
      host = "host"

  type Seg = tuple[txt: string, fg: ForegroundColor, bg: BackgroundColor,
      bright: bool]
  var segs: seq[Seg] = @[]
  segs.add((" " & user & "@" & host & " ", fgBlack, bgGreen, false))
  segs.add((" " & shortCwd() & " ", fgWhite, bgBlue, true))
  let (ok, branch, dirty) = gitInfo(getCurrentDir())
  if ok:
    var gtxt = " \uE0A0 " & branch
    if dirty:
      gtxt &= " ●"
    segs.add((gtxt & " ", fgBlack, bgYellow, false))
  if lastExit != 0:
    segs.add((" \u2718" & $lastExit & " ", fgWhite, bgRed, true))

  if power:
    for i, s in segs:
      result.addRun(s.txt, s.fg, s.bg, s.bright)
      let nextBg = if i + 1 < segs.len: segs[i + 1].bg else: bgNone
      # separator takes the previous segment bg as its foreground
      # (bg enum runs 40..47, fg enum 30..37, same order)
      let sepFg = cast[ForegroundColor](ord(s.bg) - 10)
      result.addRun(PowerSep, sepFg, nextBg, false)
  else:
    for s in segs:
      result.addRun("[" & s.txt.strip() & "] ", s.fg, bgNone, s.bright)

  let t = now().format("HH:mm")
  result.addRun(t & " ", fgCyan, bgNone, false)
  if lastExit != 0:
    result.addRun("❯ ", fgRed, bgNone, true)
  else:
    result.addRun("❯ ", fgGreen, bgNone, true)
