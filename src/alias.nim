## alias.nim - bash alias support for nish.
##
## `bash -c` is non-interactive: it never sources ~/.bashrc and never
## expands aliases, so `ll` etc. die with "command not found". nish expands
## the first word itself, bash-style: ~/.bash_aliases + ~/.bashrc are
## scanned per command (cheap line scan, always fresh), nish.yaml aliases
## overlay them. Only the first word expands (quoted first words never do);
## trailing-space values chain (`alias sudo='sudo '`); cycles stop safely.

import os, tables, sets, strutils

proc parseAliasText*(content: string): Table[string, string] =
  ## Parse `alias name=value` lines. Last definition wins. Pure, tested.
  result = initTable[string, string]()
  for raw in content.splitLines():
    var line = raw.strip()
    if line.len == 0 or line[0] == '#':
      continue
    if not line.startsWith("alias"):
      continue
    line = line["alias".len .. ^1].strip()
    let eq = line.find('=')
    if eq <= 0:
      continue
    let name = line[0 ..< eq].strip()
    if name.len == 0 or ' ' in name or '\t' in name:
      continue
    var val = line[eq + 1 .. ^1].strip()
    if val.len >= 1 and (val[0] == '\'' or val[0] == '"'):
      let q = val[0]
      let close = val.find(q, 1)
      if close < 0:
        val = val[1 .. ^1] # unterminated quote: take the rest
      else:
        val = val[1 ..< close] # comment after closing quote ignored
    else:
      let h = val.find(" #")
      if h >= 0:
        val = val[0 ..< h].strip()
    result[name] = val

proc bashAliasFiles*(): seq[string] =
  @[getHomeDir() / ".bash_aliases", getHomeDir() / ".bashrc"]

proc loadAliasFiles*(files: seq[string]): Table[string, string] =
  ## Parse alias definitions from files in order (later wins).
  result = initTable[string, string]()
  for f in files:
    try:
      for k, v in parseAliasText(readFile(f)):
        result[k] = v
    except IOError:
      discard

proc systemAliases*(): Table[string, string] =
  ## Fresh bash aliases every call (two small scans, sub-ms, never stale).
  loadAliasFiles(bashAliasFiles())

proc expandAliases*(line: string, extra, sys: Table[string, string]): string =
  ## Expand the first word via extra (nish.yaml, wins), then sys (bash).
  ## Returns the line unchanged when nothing matches.
  var i = 0
  while i < line.len and line[i] in {' ', '\t'}:
    inc i
  if i >= line.len:
    return line
  if line[i] in {'\'', '"'}:
    return line # quoted command: bash would not expand either
  var outp = line[0 ..< i]
  var rest = line[i .. ^1]
  var seen = initHashSet[string]()
  var depth = 0
  while true:
    var j = 0
    while j < rest.len and rest[j] notin {' ', '\t'}:
      inc j
    let word = rest[0 ..< j]
    let tail = if j < rest.len: rest[j .. ^1] else: ""
    var val = ""
    var found = false
    if word in extra:
      val = extra[word]
      found = true
    elif word in sys:
      val = sys[word]
      found = true
    if not found or word in seen:
      return outp & rest
    seen.incl(word)
    if depth >= 10:
      return outp & rest
    if val.len > 0 and val[^1] in {' ', '\t'}:
      # chain alias (e.g. sudo): value already separates, continue
      # expanding with the next word
      outp.add(val)
      var k = 0
      while k < tail.len and tail[k] in {' ', '\t'}:
        inc k
      rest = if k < tail.len: tail[k .. ^1] else: ""
      if rest == "":
        return outp
      inc depth
    else:
      return outp & val & tail
