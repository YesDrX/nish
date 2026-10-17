## history.nim - 10k ringbuffer with file persistence, deduped.
##
## Design (per spec):
## - File holds up to `cap` rows (~10k). Loaded once at startup into memory,
##   deduped newest-wins.
## - In memory each command appears once: re-running a command moves it to
##   newest (O(1) membership via `seen`, O(n) move only on dup, once per
##   executed command — never per keystroke).
## - During the session we never re-read the file; new lines are appended
##   with O_APPEND (atomic for small writes, safe with concurrent sessions)
##   to preserve recency across restarts. The file is deduped lazily at
##   startup truncation.
## - Truncation to `cap` happens only at startup (with slack so rewrites are
##   rare) via temp-file + atomic rename.
## - In-memory eviction of the oldest entry once over cap = the ringbuffer
##   (evicted entries leave `seen`).

import os, strutils, sequtils, sets

const DefaultHistoryCap* = 10_000
const TruncateSlack* = 1_000

type
  History* = object
    items*: seq[string] ## oldest .. newest, unique (newest wins)
    lower*: seq[string] ## cached toLowerAscii, parallel to items
    cap*: int
    path*: string
    seen*: HashSet[string] ## O(1) membership for dedup on add

proc historyPath*(): string =
  getHomeDir() / ".nish_history"

proc loadHistory*(path = "", cap = DefaultHistoryCap): History =
  result.cap = cap
  result.path = if path == "": historyPath() else: path
  result.seen = initHashSet[string]()
  var lines: seq[string] = @[]
  if fileExists(result.path):
    try:
      for line in lines(result.path):
        if line.len > 0:
          lines.add(line)
    except IOError:
      discard
  # Dedup newest-wins (file may hold duplicates from append-only recency
  # writes): single reverse pass, O(n).
  if lines.len > 0:
    var tmp = initHashSet[string]()
    var rev: seq[string] = @[]
    for i in countdown(lines.high, 0):
      if lines[i] notin tmp:
        tmp.incl(lines[i])
        rev.add(lines[i])
    lines.setLen(0)
    for i in countdown(rev.high, 0):
      lines.add(rev[i])
  if lines.len > cap + TruncateSlack:
    let kept = lines[^cap .. ^1]
    try:
      let tmp = result.path & ".tmp." & $getCurrentProcessId()
      writeFile(tmp, kept.join("\n") & "\n")
      moveFile(tmp, result.path)
    except OSError, IOError:
      discard
    lines = kept
  elif lines.len > cap:
    # file within slack: keep whole file on disk, cap memory only
    lines = lines[^cap .. ^1]
  result.items = lines
  result.lower = newSeq[string](lines.len)
  for i, s in lines:
    result.lower[i] = s.toLowerAscii()
    result.seen.incl(s)

proc len*(h: History): int = h.items.len

proc add*(h: var History, line: string) =
  ## Add a line: skip empty / whitespace-only and consecutive duplicates.
  ## Non-consecutive duplicates move to newest (O(1) check via `seen`,
  ## O(n) delete only on dup, once per executed command — never per
  ## keystroke). File is always appended to preserve recency across
  ## restarts; the file is deduped lazily at startup truncation.
  if line.strip().len == 0:
    return
  if h.items.len > 0 and h.items[^1] == line:
    return
  if line in h.seen:
    for i in 0 ..< h.items.len:
      if h.items[i] == line:
        h.items.delete(i)
        h.lower.delete(i)
        break
  else:
    h.seen.incl(line)
  h.items.add(line)
  h.lower.add(line.toLowerAscii())
  if h.items.len > h.cap:
    let excess = h.items.len - h.cap
    for i in 0 ..< excess:
      h.seen.excl(h.items[i])
    h.items.delete(0 .. excess - 1)
    h.lower.delete(0 .. excess - 1)
  try:
    var f = open(h.path, fmAppend)
    f.writeLine(line)
    f.close()
  except IOError:
    discard

proc clear*(h: var History) =
  h.items = @[]
  h.lower = @[]
  h.seen.clear()
  try:
    writeFile(h.path, "")
  except IOError:
    discard
