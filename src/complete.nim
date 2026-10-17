## complete.nim - Tab completion for filesystem paths and commands.
##
## - token containing '/' (or '\\' on Windows, or in argument position) ->
##   filesystem entries relative to the typed dir prefix ('~' expanded for
##   reading only); directories end with '/'. Dotfiles only match a dotted
##   base.
## - first token without a separator -> executables on PATH + shell builtins.
## Candidates are full-token replacements, sorted dirs-first then
## alphabetical, capped to keep Tab-cycling sane on huge dirs.

import os, strutils, algorithm, sets

const Builtins* = ["cd", "exit", "logout", "export", "unset", "history",
  "clear", "help"]
const MaxCandidates* = 500

proc sortEntries(names: var seq[tuple[name: string, isDir: bool]]) =
  names.sort(proc(a, b: tuple[name: string, isDir: bool]): int =
    if a.isDir != b.isDir:
      (if a.isDir: -1 else: 1)
    else:
      cmp(a.name, b.name))

proc listMatches*(dirRead, base: string): seq[tuple[name: string,
    isDir: bool]] =
  ## Raw (name, isDir) entries of dirRead starting with base.
  when defined(windows):
    let baseLow = base.toLowerAscii()
  try:
    for kind, path in walkDir(dirRead):
      let name = lastPathPart(path)
      when defined(windows):
        if not name.toLowerAscii().startsWith(baseLow):
          continue
      else:
        if not name.startsWith(base):
          continue
      if name.startsWith(".") and not base.startsWith("."):
        continue
      result.add((name, kind in {pcDir, pcLinkToDir}))
  except OSError:
    discard
  sortEntries(result)
  if result.len > MaxCandidates:
    result.setLen(MaxCandidates)

proc expandForRead(dir: string): string =
  if dir == "" or dir == ".":
    "."
  elif dir == "~" or dir == "~/" or dir == "~\\":
    getHomeDir()
  elif dir.startsWith("~/") or dir.startsWith("~\\"):
    getHomeDir() & dir[2 .. ^1]
  else:
    dir

proc lastSepPos(token: string): int =
  ## Index of the last path separator, or -1. Windows accepts both
  ## '/' (AltSep, also works in PowerShell) and '\\' (DirSep).
  when defined(windows):
    max(token.rfind('/'), token.rfind('\\'))
  else:
    token.rfind('/')

proc pathCandidates*(token: string): seq[string] =
  ## Full-token replacements; the typed dir prefix is preserved.
  ## Directories end with DirSep ('/' on POSIX, '\\' on Windows; both
  ## work in PowerShell).
  var dirPart, base: string
  if token == "~":
    dirPart = "~" & $DirSep
    base = ""
  else:
    let slash = lastSepPos(token)
    if slash < 0:
      dirPart = ""
      base = token
    else:
      dirPart = token[0 .. slash]
      base = token[slash + 1 .. ^1]
  let dirRead = if dirPart == "": "." else: expandForRead(dirPart)
  for (name, isDir) in listMatches(dirRead, base):
    if isDir:
      result.add(dirPart & name & $DirSep)
    else:
      result.add(dirPart & name)

proc commandCandidates*(token: string, pathEnv = ""): seq[string] =
  ## Executable names on PATH + builtins starting with token.
  let pe = if pathEnv == "": getEnv("PATH", "") else: pathEnv
  var seen = initHashSet[string]()
  when defined(windows):
    let tokLow = token.toLowerAscii()
    for b in Builtins:
      if b.toLowerAscii().startsWith(tokLow) and b notin seen:
        seen.incl(b)
        result.add(b)
    # Windows has no exec bits; executability is by extension (PATHEXT).
    var exts: seq[string] = @[]
    for e in getEnv("PATHEXT", ".COM;.EXE;.BAT;.CMD;.PS1").split(';'):
      let t = e.strip().toLowerAscii()
      if t.len > 0:
        exts.add(t)
    for d0 in pe.split(PathSep):
      let d = d0.strip().strip(chars = {'"', '\''})
      if d == "":
        continue
      try:
        for kind, path in walkDir(d):
          if kind == pcDir:
            continue
          let name = lastPathPart(path)
          if name.toLowerAscii() in seen or
              not name.toLowerAscii().startsWith(tokLow):
            continue
          let ext = splitFile(name).ext.toLowerAscii()
          if ext in exts:
            seen.incl(name.toLowerAscii())
            result.add(name)
      except OSError:
        discard
  else:
    for b in Builtins:
      if b.startsWith(token) and b notin seen:
        seen.incl(b)
        result.add(b)
    for d in pe.split(PathSep):
      if d == "":
        continue
      try:
        for kind, path in walkDir(d):
          if kind == pcDir:
            continue
          let name = lastPathPart(path)
          if name in seen or not name.startsWith(token):
            continue
          try:
            let perms = getFilePermissions(path)
            if fpUserExec in perms or fpGroupExec in perms or
                fpOthersExec in perms:
              seen.incl(name)
              result.add(name)
          except OSError:
            discard
      except OSError:
        discard
  result.sort(cmp)
  if result.len > MaxCandidates:
    result.setLen(MaxCandidates)

proc completeCandidates*(token: string, firstToken: bool,
    pathEnv = ""): seq[string] =
  when defined(windows):
    if '/' in token or '\\' in token or not firstToken:
      pathCandidates(token)
    else:
      commandCandidates(token, pathEnv)
  else:
    if '/' in token or not firstToken:
      pathCandidates(token)
    else:
      commandCandidates(token, pathEnv)

proc isCommandPosition*(buf: string, tokStart: int): bool =
  ## True when the token at tokStart is in command position: start of line
  ## or right after |, &, ; or ( (ignoring whitespace).
  var i = tokStart - 1
  while i >= 0 and buf[i] in {' ', '\t'}:
    dec i
  if i < 0:
    return true
  buf[i] in {'|', '&', ';', '('}
