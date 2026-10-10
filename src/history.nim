## history.nim - 10k ringbuffer with file persistence.
##
## Design (per spec):
## - File holds up to `cap` rows (~10k). Loaded once at startup into memory.
## - During the session we never re-read the file; new lines are appended
##   with O_APPEND (atomic for small writes, safe with concurrent sessions).
## - Truncation to `cap` happens only at startup (with slack so rewrites are
##   rare) via temp-file + atomic rename.
## - In-memory eviction of the oldest entry once over cap = the ringbuffer.

import os, strutils, sequtils

const DefaultHistoryCap* = 10_000
const TruncateSlack* = 1_000

type
  History* = object
    items*: seq[string] ## oldest .. newest
    lower*: seq[string] ## cached toLowerAscii, parallel to items
    cap*: int
    path*: string

proc historyPath*(): string =
  getHomeDir() / ".nish_history"

proc loadHistory*(path = "", cap = DefaultHistoryCap): History =
  result.cap = cap
  result.path = if path == "": historyPath() else: path
  var lines: seq[string] = @[]
  if fileExists(result.path):
    try:
      for line in lines(result.path):
        if line.len > 0:
          lines.add(line)
    except IOError:
      discard
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

proc len*(h: History): int = h.items.len

proc add*(h: var History, line: string) =
  ## Add a line: skip empty / whitespace-only and consecutive duplicates,
  ## evict oldest past cap, append to the file for future sessions.
  if line.strip().len == 0:
    return
  if h.items.len > 0 and h.items[^1] == line:
    return
  h.items.add(line)
  h.lower.add(line.toLowerAscii())
  if h.items.len > h.cap:
    let excess = h.items.len - h.cap
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
  try:
    writeFile(h.path, "")
  except IOError:
    discard
