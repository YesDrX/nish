## editor.nim - illwill-based line editor with live history dropdown.
##
## Uses illwill as the TUI framework:
## - illwillInit(fullscreen=false) / illwillDeinit() for terminal setup
##   (non-canonical input, cross-platform key layer, SIGTSTP handling)
## - getKey() polling for all input incl. arrows / Home / End / Delete
## - TerminalBuffer as the composition surface: prompt runs + input line +
##   suggestion rows are composed with tb.write / colors, then blitted.
##
## Why a custom blit instead of tb.display()? display() writes at absolute
## screen coordinates (fullscreen model). A shell scrolls: the prompt lives
## on the current tty line and command output must keep flowing below, so we
## blit the small buffer at the cursor with \r / \e[J / cursor-up restores.
##
## UX: typing filters history live (no Ctrl-R needed) but selects nothing,
## so Enter always runs exactly what you typed unless you explicitly pick
## an entry. Up/Down (or Ctrl-P/N) move the highlight like a visual menu
## (first step selects the top entry, then Up moves up and Down moves down,
## wrapping at the ends); the selection is pulled into the command line so
## it can be edited directly. Further Up/Down keeps browsing the same
## filtered list; any edit resumes live filtering.
## Up/Down on an empty buffer opens and browses recent history. Enter runs
## the selection if any, else the buffer. Tab completes the current token
## against filesystem paths / PATH commands (repeat Tab to cycle
## candidates), Esc dismisses the list. Ctrl+Left/Right (also Alt+Left/Right
## and Ctrl+< / Ctrl+> where the terminal provides them) jump by word.
## NOTE (v1): wide (double-column) runes count as 1 column for cursor math.
##
## Input decoding: illwill owns terminal setup + rendering, but its key
## decoder cannot see Ctrl/Alt+arrows (it eats them and leaks "5D"-style
## garbage into the buffer) nor C0 byte 0x1E (Ctrl+>), so this module
## reads the tty itself with a superset decoder and unknown sequences are
## consumed fully (never leaked). ISIG stays on: Ctrl+C arrives via SIGINT
## and Ctrl+\ / Ctrl+< (both C0 0x1C, indistinguishable) via SIGQUIT, which
## nish catches as word-left instead of dying (children keep the default
## disposition, so Ctrl+\ still quits a runaway child).

import illwill, unicode, os, strutils
when defined(posix):
  import posix except Key # posix.Key (SysV IPC) would shadow illwill.Key
when defined(windows):
  import winlean
import prompt, history, search, complete, config

const TokSeps = {' ', '\t', '|', '&', ';', '(', ')', '<', '>', '$', '"',
  '\'', '`', '=', ','}

type TabState = object
  active: bool
  cands: seq[string]
  idx: int
  afterText: string
  afterCursor: int

type
  LineResult* = object
    line*: string
    eof*: bool ## Ctrl-D on empty buffer
    aborted*: bool ## Ctrl-C

type
  KKind* = enum ## decoded input key (superset of what illwill delivers)
    kkNone, kkText, kkEnter, kkTab, kkEscape, kkBackspace, kkDelete,
    kkLeft, kkRight, kkUp, kkDown, kkHome, kkEnd,
    kkWordLeft, kkWordRight,
    kkCtrlA, kkCtrlB, kkCtrlE, kkCtrlF, kkCtrlP, kkCtrlN,
    kkCtrlU, kkCtrlK, kkCtrlW, kkAltBackspace, kkCtrlL, kkCtrlD, kkCtrlC

proc c0Kind*(b: int): KKind =
  ## Classify a C0 control byte (also 0x7F). Pure, unit-tested.
  case b:
  of 0x09: kkTab
  of 0x0A, 0x0D: kkEnter
  of 0x08, 0x7F: kkBackspace
  of 0x01: kkCtrlA
  of 0x02: kkCtrlB
  of 0x05: kkCtrlE
  of 0x06: kkCtrlF
  of 0x10: kkCtrlP
  of 0x0E: kkCtrlN
  of 0x15: kkCtrlU
  of 0x0B: kkCtrlK
  of 0x17: kkCtrlW
  of 0x0C: kkCtrlL
  of 0x04: kkCtrlD
  of 0x03: kkCtrlC
  of 0x1C: kkWordLeft # Ctrl+\ and Ctrl+< share this byte
  of 0x1E: kkWordRight # Ctrl+> (and Ctrl+^)
  else: kkNone

proc csiKind*(params: string, final: char): KKind =
  ## Classify a CSI sequence by parameter string + final byte.
  ## Pure, unit-tested. Covers plain/modified arrows, Home/End/Delete and
  ## xterm modifyOtherKeys Ctrl+< (27;5;60~) / Ctrl+> (27;5;62~).
  case final:
  of 'A':
    if params == "" or params == "1;5" or params == "1;3": kkUp
    else: kkNone
  of 'B':
    if params == "" or params == "1;5" or params == "1;3": kkDown
    else: kkNone
  of 'C':
    if params == "1;5" or params == "1;3": kkWordRight
    elif params == "": kkRight
    else: kkNone
  of 'D':
    if params == "1;5" or params == "1;3": kkWordLeft
    elif params == "": kkLeft
    else: kkNone
  of 'H': kkHome
  of 'F': kkEnd
  of 'Z': kkNone
  of '~':
    case params:
    of "1", "7": kkHome
    of "4", "8": kkEnd
    of "3": kkDelete
    of "27;5;60": kkWordLeft
    of "27;5;62": kkWordRight
    else: kkNone
  else: kkNone

proc wordLeftFrom*(s: string, pos: int): int =
  ## Buffer index of the start of the word before pos (space-delimited,
  ## matching CtrlW). Pure, unit-tested.
  var i = min(pos, s.len)
  while i > 0 and s[i - 1] == ' ':
    dec i
  while i > 0 and s[i - 1] != ' ':
    dec i
  i

proc wordRightFrom*(s: string, pos: int): int =
  ## Buffer index of the start of the next word at/after pos. Pure.
  var i = min(max(pos, 0), s.len)
  while i < s.len and s[i] != ' ':
    inc i
  while i < s.len and s[i] == ' ':
    inc i
  i

proc asciiKind*(b0: int): KKind =
  ## Classify a 7-bit byte: printables (0x20..0x7E) are text, everything
  ## else (including 0x7F DEL!) goes through c0Kind. Pure, unit-tested.
  if b0 >= 0x20 and b0 < 0x7F: kkText
  else: c0Kind(b0)

var ctrlCFlag {.volatile.}: bool = false
when defined(posix):
  var sigQuitFlag {.volatile.}: bool = false

type EditorMode = enum mOff, mOn, mSuspended
var gMode = mOff

when defined(posix):
  proc sigIntHandler(sig: cint) {.noconv.} =
    ctrlCFlag = true

  proc sigQuitHandler(sig: cint) {.noconv.} =
    # C0 0x1C is both Ctrl+\ and (on basic terminals) Ctrl+<. Catching it
    # keeps the shell alive; the editor treats it as word-left. Caught
    # dispositions reset on exec, so spawned children keep normal SIGQUIT.
    sigQuitFlag = true

when defined(windows):
  proc winCtrlCHook() {.noconv.} =
    ctrlCFlag = true

  proc getConsoleMode(hConsoleHandle: Handle,
      dwMode: ptr DWORD): WINBOOL {.
      stdcall, dynlib: "kernel32", importc: "GetConsoleMode".}
  proc setConsoleMode(hConsoleHandle: Handle,
      dwMode: DWORD): WINBOOL {.
      stdcall, dynlib: "kernel32", importc: "SetConsoleMode".}
  const EnableVtProc = 0x0004.DWORD # ENABLE_VIRTUAL_TERMINAL_PROCESSING

  proc enableVT() =
    ## PowerShell/conhost need VT processing for the ANSI blit.
    ## No-op when the handle is redirected; never fails the shell.
    try:
      var mode: DWORD = 0
      let hOut = getStdHandle(STD_OUTPUT_HANDLE)
      if getConsoleMode(hOut, addr mode) != 0:
        discard setConsoleMode(hOut, mode or EnableVtProc)
    except CatchableError:
      discard

proc editorInit*() =
  when defined(windows):
    enableVT()
  illwillInit(fullscreen = false)
  showCursor()
  stdout.flushFile()
  when defined(posix):
    signal(SIGINT, sigIntHandler)
    signal(SIGQUIT, sigQuitHandler)
  when defined(windows):
    setControlCHook(winCtrlCHook)
  gMode = mOn

proc editorDeinit*() =
  if gMode == mOn:
    illwillDeinit()
  gMode = mOff

proc takeCtrlC*(): bool =
  if ctrlCFlag:
    ctrlCFlag = false
    return true
  false

proc takeSigQuit*(): bool =
  when defined(posix):
    if sigQuitFlag:
      sigQuitFlag = false
      return true
    false
  else:
    false

proc suspendForExec*() =
  ## Restore cooked terminal before spawning the child (no-op in batch mode).
  stdout.flushFile()
  if gMode == mOn:
    illwillDeinit()
    gMode = mSuspended

proc resumeAfterExec*() =
  if gMode == mSuspended:
    illwillInit(fullscreen = false)
    showCursor()
    stdout.flushFile()
    when defined(posix):
      signal(SIGINT, sigIntHandler) # re-arm (C signal() may be one-shot)
      signal(SIGQUIT, sigQuitHandler)
    when defined(windows):
      enableVT()
      setControlCHook(winCtrlCHook)
    gMode = mOn
  discard takeCtrlC()
  discard takeSigQuit() # e.g. Ctrl+\ that quit the child, not us

when defined(posix):
  proc stdinReady(timeoutMs: int): bool =
    var tv: Timeval
    tv.tv_sec = Time(timeoutMs div 1000)
    tv.tv_usec = (timeoutMs mod 1000) * 1000
    var fds: TFdSet
    FD_ZERO(fds)
    FD_SET(STDIN_FILENO, fds)
    let r = select(STDIN_FILENO + 1, addr fds, nil, nil, addr tv)
    r > 0 and FD_ISSET(STDIN_FILENO, fds) != 0

  proc readByte(): int =
    var c: char
    if read(cint(STDIN_FILENO), addr c, 1) == 1: ord(c) else: -1

  proc readByteTimeout(ms: int): int =
    if stdinReady(ms): readByte() else: -1

  proc utf8Len(lead: int): int =
    if lead < 0x80: 1
    elif lead < 0xC0: 1 # stray continuation byte: take singly, steal nothing
    elif lead < 0xE0: 2
    elif lead < 0xF0: 3
    elif lead < 0xF8: 4
    else: 1

  proc readKeys(timeoutMs: int): tuple[kind: KKind, text: string] =
    ## Own tty decoder (illwill can't see modified arrows / 0x1E and leaks
    ## partial sequences as typed text). Unknown sequences are consumed
    ## fully so they never pollute the buffer.
    if not stdinReady(timeoutMs):
      return (kkNone, "")
    let b0 = readByte()
    if b0 < 0:
      return (kkNone, "")
    if b0 == 0x1B:
      # ESC: wait briefly for a continuation so lone Esc still works
      # (readline-style; without this Esc fuses with the next keystroke)
      let b1 = readByteTimeout(60)
      if b1 < 0:
        return (kkEscape, "")
      if b1 == ord('['):
        var params = ""
        while true:
          let b = readByteTimeout(60)
          if b < 0:
            return (kkNone, "")
          let c = chr(b)
          if (c >= '0' and c <= '9') or c == ';':
            params.add(c)
            continue
          return (csiKind(params, c), "")
      elif b1 == ord('O'):
        let b2 = readByteTimeout(60)
        if b2 < 0:
          return (kkNone, "")
        case chr(b2):
        of 'A': result = (kkUp, "")
        of 'B': result = (kkDown, "")
        of 'C': result = (kkRight, "")
        of 'D': result = (kkLeft, "")
        of 'H': result = (kkHome, "")
        of 'F': result = (kkEnd, "")
        else: result = (kkNone, "")
      else:
        # Alt+key (ESC-prefixed)
        case chr(b1):
        of 'b', 'B': result = (kkWordLeft, "")
        of 'f', 'F': result = (kkWordRight, "")
        of '\x7F': result = (kkAltBackspace, "")
        else: result = (kkNone, "")
    elif b0 < 0x80:
      if asciiKind(b0) == kkText: result = (kkText, $chr(b0))
      else: result = (c0Kind(b0), "")
    else:
      # UTF-8 passthrough as one unit (illwill drops these bytes)
      var s = $chr(b0)
      for _ in 1 ..< utf8Len(b0):
        let b = readByteTimeout(60)
        if b < 0:
          break
        s.add(chr(b))
      result = (kkText, s)

when defined(windows):
  const
    VkBack = 0x08
    VkTab = 0x09
    VkReturn = 0x0D
    VkEscape = 0x1B
    VkEnd = 0x23
    VkHome = 0x24
    VkLeft = 0x25
    VkUp = 0x26
    VkRight = 0x27
    VkDown = 0x28
    VkDelete = 0x2E
    LeftAltPressed = 0x0002.DWORD
    RightAltPressed = 0x0001.DWORD
    LeftCtrlPressed = 0x0008.DWORD
    RightCtrlPressed = 0x0004.DWORD

  proc winHasCtrl(state: DWORD): bool =
    (state and (LeftCtrlPressed or RightCtrlPressed)) != 0.DWORD

  proc winHasAlt(state: DWORD): bool =
    (state and (LeftAltPressed or RightAltPressed)) != 0.DWORD

  proc readWindowsKey(timeoutMs: int): tuple[kind: KKind, text: string] =
    ## Native console reader (winlean ReadConsoleInputW). illwill's key
    ## layer drops Ctrl/Alt modifiers on arrows, so Ctrl+Left etc. would
    ## collapse to plain arrows; reading INPUT_RECORDs directly preserves
    ## them for word jumps. Mirrors the POSIX decoder's KKind contract.
    let hIn = getStdHandle(STD_INPUT_HANDLE)
    if waitForSingleObject(hIn, int32(timeoutMs)) != WAIT_OBJECT_0:
      return (kkNone, "")
    var rec = KEY_EVENT_RECORD()
    var nRead: cint = 0
    for _ in 0 ..< 32:
      if waitForSingleObject(hIn, 0) != WAIT_OBJECT_0:
        return (kkNone, "")
      if readConsoleInput(hIn, addr rec, 1, addr nRead) == 0 or nRead == 0:
        return (kkNone, "")
      if rec.eventType != 1 or rec.bKeyDown == 0:
        continue # key release or non-key event (mouse/focus)
      let vk = int(rec.wVirtualKeyCode)
      let uch = int(rec.uChar)
      let state = rec.dwControlKeyState
      let hasCtrl = winHasCtrl(state)
      let hasAlt = winHasAlt(state)
      if hasAlt:
        # Alt+letter word jumps (console reports the letter + Alt flag);
        # swallow other Alt combos so they never leak into the buffer.
        if uch == ord('b') or uch == ord('B'):
          return (kkWordLeft, "")
        if uch == ord('f') or uch == ord('F'):
          return (kkWordRight, "")
        if vk == VkBack:
          return (kkAltBackspace, "")
        if vk == VkLeft:
          return (kkWordLeft, "")
        if vk == VkRight:
          return (kkWordRight, "")
        if vk == VkUp:
          return (kkUp, "")
        if vk == VkDown:
          return (kkDown, "")
        return (kkNone, "")
      if hasCtrl:
        if vk == VkLeft:
          return (kkWordLeft, "")
        if vk == VkRight:
          return (kkWordRight, "")
        if vk == VkUp:
          return (kkUp, "")
        if vk == VkDown:
          return (kkDown, "")
        # Ctrl+letter C0 codes fall through to uch handling below.
      if uch == 0:
        case vk:
        of VkLeft: return (kkLeft, "")
        of VkRight: return (kkRight, "")
        of VkUp: return (kkUp, "")
        of VkDown: return (kkDown, "")
        of VkHome: return (kkHome, "")
        of VkEnd: return (kkEnd, "")
        of VkDelete: return (kkDelete, "")
        of VkBack: return (kkBackspace, "")
        of VkTab: return (kkTab, "")
        of VkReturn: return (kkEnter, "")
        of VkEscape: return (kkEscape, "")
        else: return (kkNone, "")
      else:
        if uch == 0x1B:
          return (kkEscape, "")
        if uch == 26:
          # Ctrl+Z is the Windows console EOF gesture (Ctrl+D on POSIX).
          return (kkCtrlD, "")
        if uch >= 0x20 and uch < 0x7F:
          return (kkText, $chr(uch))
        elif uch >= 0x80 and uch <= 0x7FFF:
          # BMP passthrough (illwill drops these); v1 cursor math still
          # counts runes as 1 column, same as the POSIX path.
          return (kkText, $Rune(uch))
        else:
          return (c0Kind(uch), "")
    return (kkNone, "")

proc nextKey*(): tuple[kind: KKind, text: string] =
  ## One non-blocking input poll (~10ms). POSIX uses the tty decoder;
  ## Windows uses the native console reader; other platforms fall back
  ## to illwill's key layer.
  when defined(posix):
    readKeys(10)
  elif defined(windows):
    readWindowsKey(10)
  else:
    let k = getKey()
    if k == Key.None:
      sleep(10)
      return (kkNone, "")
    let code = ord(k)
    if code in 32 .. 126:
      return (kkText, $chr(code))
    case k:
    of Key.Enter: result = (kkEnter, "")
    of Key.Tab: result = (kkTab, "")
    of Key.Escape: result = (kkEscape, "")
    of Key.Backspace, Key.CtrlH: result = (kkBackspace, "")
    of Key.Delete: result = (kkDelete, "")
    of Key.Left, Key.CtrlB: result = (kkLeft, "")
    of Key.Right, Key.CtrlF: result = (kkRight, "")
    of Key.Home, Key.CtrlA: result = (kkHome, "")
    of Key.End, Key.CtrlE: result = (kkEnd, "")
    of Key.Up, Key.CtrlP: result = (kkUp, "")
    of Key.Down, Key.CtrlN: result = (kkDown, "")
    of Key.CtrlU: result = (kkCtrlU, "")
    of Key.CtrlK: result = (kkCtrlK, "")
    of Key.CtrlW: result = (kkCtrlW, "")
    of Key.CtrlL: result = (kkCtrlL, "")
    of Key.CtrlD: result = (kkCtrlD, "")
    of Key.CtrlC: result = (kkCtrlC, "")
    else: result = (kkNone, "")

proc truncateVis*(s: string, maxRunes: int): string =
  if maxRunes <= 0:
    return ""
  var n = 0
  for r in s.runes:
    if n >= maxRunes:
      break
    result.add($r)
    inc n

proc blit(tb: TerminalBuffer, nrows, cursorCol: int) =
  ## Draw tb (1 input row + nrows suggestion rows) at the cursor line,
  ## then restore the cursor onto the input row at cursorCol.
  ## NOTE: \e[K / \e[J erase using the *current* background color, so attrs
  ## are always reset to default before any erase - otherwise a highlight
  ## row's bg bleeds onto neighbouring rows.
  hideCursor()
  stdout.write("\e[0m\r\e[J") # default attrs, line start, clear old dropdown
  for y in 0 ..< tb.height:
    var cur = ""
    if y > 0:
      stdout.write("\e[0m\n\e[K")
    # trim trailing blank cells so we never pad-wrap
    var rowEnd = -1
    for x in 0 ..< tb.width:
      let c = tb[x, y]
      if c.ch != " ".runeAt(0) or c.fg != fgNone or c.bg != bgNone or
          c.style != {}:
        rowEnd = x
    if rowEnd < 0:
      continue
    for x in 0 .. rowEnd:
      let c = tb[x, y]
      # attribute signature for this cell
      var sig = $ord(c.fg) & "/" & $ord(c.bg) & "/"
      for st in c.style:
        sig.add($ord(st) & ",")
      if sig != cur:
        cur = sig
        var parts: seq[string] = @[]
        for st in c.style:
          parts.add($ord(st))
        if c.fg != fgNone:
          parts.add($ord(c.fg))
        if c.bg != bgNone:
          parts.add($ord(c.bg))
        if parts.len == 0:
          stdout.write("\e[0m")
        else:
          stdout.write("\e[0;" & parts.join(";") & "m")
      stdout.write($c.ch)
  stdout.write("\e[0m")
  if nrows > 0:
    stdout.write("\e[" & $nrows & "A")
  stdout.write("\r")
  if cursorCol > 0:
    stdout.write("\e[" & $cursorCol & "C")
  # show BEFORE flush: showCursor buffers into stdout, and flushing first
  # would leave the cursor hidden on the terminal while idle (exactly
  # when the user looks for it).
  showCursor()
  stdout.flushFile()

proc finalizeLine(pr: Prompt, buf: string, marker = "") =
  ## Leave `prompt+buf` on screen, clear the dropdown, go to a fresh line.
  let endCol = pr.visibleLen + buf.len
  stdout.write("\e[0m\r")
  if endCol > 0:
    stdout.write("\e[" & $endCol & "C")
  stdout.write("\e[J")
  if marker.len > 0:
    stdout.write(marker)
  stdout.write("\n")
  stdout.flushFile()

proc readLine*(pr: Prompt, hist: History, cfg: Config): LineResult =
  var buf = ""
  var cursor = 0 # byte index == display col (ASCII input in v1)
  var sel = -1 # -1 = nothing selected: Enter runs the typed buffer
  var dismissed = false
  # browse state: Up/Down pulls the selection into buf for direct editing.
  # navQuery freezes the filter the list was built from, so continued
  # Up/Down keeps browsing that list instead of re-filtering the pulled
  # text. Any text edit ends browsing (navActive=false at edit sites).
  var navActive = false
  var navQuery = ""
  var tab = TabState()
  ## Tab validity is self-invalidating: a cycle continues only while the
  ## buffer and cursor are exactly as the last Tab left them, so plain
  ## edits need no explicit reset.

  proc currentSug(): seq[string] =
    ## While browsing (navActive) the list is built from the frozen
    ## navQuery. Otherwise it opens once the user typed something.
    if dismissed:
      @[]
    elif navActive:
      filterHistory(hist, navQuery, cfg.suggestCount)
    elif buf.strip().len == 0:
      @[]
    else:
      filterHistory(hist, buf, cfg.suggestCount)

  proc render() =
    var sug = currentSug()
    if sug.len == 0:
      sel = -1
    elif sel >= sug.len:
      sel = sug.len - 1
    let w = max(terminalWidth(), 20)
    var tb = newTerminalBuffer(w, 1 + sug.len)
    for r in pr.runs:
      tb.setForegroundColor(r.fg, bright = r.bright)
      tb.setBackgroundColor(r.bg)
      tb.write(r.text)
    tb.resetAttributes()
    tb.write(buf)
    for i, s in sug:
      let row = i + 1
      let marker = if i == sel: "> " else: "  "
      if i == sel:
        # compact highlight: only the text itself, never padded to full
        # width (a full-width bar looks broken on dark terminals)
        tb.setBackgroundColor(bgBlue)
        tb.setForegroundColor(fgWhite, bright = true)
        let disp = truncateVis(s, w - marker.runeLen)
        tb.write(0, row, marker & disp)
        tb.resetAttributes()
      else:
        tb.resetAttributes()
        tb.setForegroundColor(fgCyan)
        tb.write(0, row, marker & truncateVis(s, w - marker.runeLen))
    tb.resetAttributes()
    blit(tb, sug.len, pr.visibleLen + cursor)

  proc goWordLeft() =
    let i = wordLeftFrom(buf, cursor)
    if i != cursor:
      cursor = i
      render()

  proc goWordRight() =
    let i = wordRightFrom(buf, cursor)
    if i != cursor:
      cursor = i
      render()

  render()
  while true:
    if takeCtrlC():
      finalizeLine(pr, buf, "^C")
      return LineResult(line: "", aborted: true)
    if takeSigQuit():
      goWordLeft() # 0x1C doubles as Ctrl+\ and Ctrl+<; never kill the shell
      continue
    let (kk, txt) = nextKey()
    if kk == kkNone:
      continue
    if kk == kkText:
      let tail = if cursor < buf.len: buf[cursor .. ^1] else: ""
      buf = buf[0 ..< cursor] & txt & tail
      cursor += txt.len
      dismissed = false
      navActive = false
      sel = -1
      render()
      continue
    case kk
    of kkEnter:
      # runs the highlighted entry if one is selected, else the typed
      # buffer as-is (nothing is pre-selected when the list opens)
      let sug = currentSug()
      if not dismissed and sel >= 0 and sel < sug.len:
        buf = sug[sel]
      finalizeLine(pr, buf)
      return LineResult(line: buf)
    of kkTab:
      # filesystem / command completion; repeated Tab cycles candidates
      var ts = cursor
      while ts > 0 and buf[ts - 1] notin TokSeps:
        dec ts
      if tab.active and tab.cands.len > 0 and buf == tab.afterText and
          cursor == tab.afterCursor:
        tab.idx = (tab.idx + 1) mod tab.cands.len
        let tail = if cursor < buf.len: buf[cursor .. ^1] else: ""
        buf = buf[0 ..< ts] & tab.cands[tab.idx] & tail
        cursor = ts + tab.cands[tab.idx].len
        tab.afterText = buf
        tab.afterCursor = cursor
        dismissed = false
        navActive = false
        sel = -1
        render()
      else:
        let token = buf[ts ..< cursor]
        var cands: seq[string] = @[]
        if token.len > 0:
          cands = completeCandidates(token, isCommandPosition(buf, ts))
        elif ts > 0 and not isCommandPosition(buf, ts):
          cands = pathCandidates("") # bare argument: everything here
        if cands.len == 0:
          # no path/command match: accept the highlighted history entry,
          # but only when the whole line is the token (never clobber args)
          let sug = currentSug()
          if ts == 0 and cursor == buf.len and not dismissed and
              buf.len > 0 and sug.len > 0 and sel >= 0 and sel < sug.len:
            buf = sug[sel]
            cursor = buf.len
            dismissed = false
            navActive = false
            sel = -1
            render()
        else:
          tab = TabState(active: true, cands: cands, idx: 0,
            afterText: "", afterCursor: 0)
          let tail = if cursor < buf.len: buf[cursor .. ^1] else: ""
          buf = buf[0 ..< ts] & cands[0] & tail
          cursor = ts + cands[0].len
          tab.afterText = buf
          tab.afterCursor = cursor
          dismissed = false
          navActive = false
          sel = -1
          render()
    of kkEscape:
      # closes the list; pulled text stays in the buffer for editing
      if not dismissed:
        dismissed = true
        navActive = false
        render()
    of kkBackspace:
      if cursor > 0:
        dec cursor
        let tail = if cursor + 1 < buf.len: buf[cursor + 1 .. ^1] else: ""
        buf = buf[0 ..< cursor] & tail
        dismissed = false
        navActive = false
        sel = -1
        render()
    of kkDelete:
      if cursor < buf.len:
        let tail = if cursor + 1 < buf.len: buf[cursor + 1 .. ^1] else: ""
        buf = buf[0 ..< cursor] & tail
        dismissed = false
        navActive = false
        sel = -1
        render()
    of kkCtrlD:
      if buf.len == 0:
        finalizeLine(pr, buf, "exit")
        return LineResult(line: "", eof: true)
      if cursor < buf.len:
        let tail = if cursor + 1 < buf.len: buf[cursor + 1 .. ^1] else: ""
        buf = buf[0 ..< cursor] & tail
        dismissed = false
        navActive = false
        sel = -1
        render()
    of kkLeft, kkCtrlB:
      if cursor > 0:
        dec cursor
        render()
    of kkRight, kkCtrlF:
      if cursor < buf.len:
        inc cursor
        render()
    of kkHome, kkCtrlA:
      if cursor != 0:
        cursor = 0
        render()
    of kkEnd, kkCtrlE:
      if cursor != buf.len:
        cursor = buf.len
        render()
    of kkUp, kkCtrlP:
      # Visual menu movement: first step selects the top (most recent)
      # entry; further steps move up, wrapping to the bottom. The
      # selection is pulled into the buffer for editing; the filter stays
      # frozen (navQuery) while browsing, any text edit resumes filtering.
      if dismissed:
        dismissed = false
        navActive = false
        sel = -1
      elif navActive and sel >= 0:
        let cur = currentSug()
        if sel >= cur.len or cur[sel] != buf:
          navActive = false # buffer changed: restart from new text
          sel = -1
      if not navActive:
        navActive = true
        navQuery = buf
      let sugUp = currentSug()
      if sugUp.len == 0:
        navActive = false
      else:
        sel = if sel < 0: 0 else: (sel - 1 + sugUp.len) mod sugUp.len
        buf = sugUp[sel]
        cursor = buf.len
        render()
    of kkDown, kkCtrlN:
      # Mirror of Up: first step selects the top entry, further steps
      # move down, wrapping to the top.
      if dismissed:
        dismissed = false
        navActive = false
        sel = -1
      elif navActive and sel >= 0:
        let cur = currentSug()
        if sel >= cur.len or cur[sel] != buf:
          navActive = false
          sel = -1
      if not navActive:
        navActive = true
        navQuery = buf
      let sugDown = currentSug()
      if sugDown.len == 0:
        navActive = false
      else:
        sel = if sel < 0: 0 else: (sel + 1) mod sugDown.len
        buf = sugDown[sel]
        cursor = buf.len
        render()
    of kkCtrlU: # kill to start
      if cursor > 0:
        buf = if cursor < buf.len: buf[cursor .. ^1] else: ""
        cursor = 0
        dismissed = false
        navActive = false
        sel = -1
        render()
    of kkCtrlK: # kill to end
      if cursor < buf.len:
        buf = buf[0 ..< cursor]
        dismissed = false
        navActive = false
        sel = -1
        render()
    of kkCtrlW, kkAltBackspace: # kill word before cursor
      if cursor > 0:
        var i = cursor
        while i > 0 and buf[i - 1] == ' ':
          dec i
        while i > 0 and buf[i - 1] != ' ':
          dec i
        let tail = if cursor < buf.len: buf[cursor .. ^1] else: ""
        buf = buf[0 ..< i] & tail
        cursor = i
        dismissed = false
        navActive = false
        sel = -1
        render()
    of kkCtrlL:
      stdout.write("\e[2J\e[H")
      stdout.flushFile()
      render()
    of kkWordLeft: # Ctrl+Left / Alt+Left / Ctrl+< (also Ctrl+\, same byte)
      goWordLeft()
    of kkWordRight: # Ctrl+Right / Alt+Right / Ctrl+>
      goWordRight()
    of kkCtrlC:
      finalizeLine(pr, buf, "^C")
      return LineResult(line: "", aborted: true)
    else:
      discard
