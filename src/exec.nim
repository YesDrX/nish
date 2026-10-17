## exec.nim - command execution.
##
## v1 strategy (per spec): everything is passed through to the shell
## (`bash -c <line>` on POSIX, `powershell -Command <line>` on Windows,
## inheriting stdio so interactive programs work).
## A few builtins must run in-process to be meaningful: cd, exit,
## export/unset, history, clear, help. First-word aliases (bash files +
## nish.yaml) expand before dispatch, so `alias ll='ls -l'` keeps working.

import os, osproc, strutils, tables
import history, editor, config, alias

proc shellName*(): string =
  when defined(windows):
    getEnv("NISH_SHELL", "powershell")
  else:
    getEnv("NISH_SHELL", "bash")

proc shellBase*(): string =
  ## Lowercase exe name without extension: powershell, pwsh, cmd, bash...
  var b = extractFilename(shellName()).toLowerAscii()
  if b.endsWith(".exe"):
    b = b[0 .. ^5]
  b

proc runPassthrough*(line: string): int =
  ## Run via the configured shell with inherited stdio. Restores cooked
  ## mode around it. POSIX: `bash -c`; Windows PowerShell:
  ## `powershell -NoLogo -NoProfile -Command`; cmd: `cmd /c`.
  suspendForExec()
  let shell = shellName()
  let base = shellBase()
  var args: seq[string]
  if base in ["powershell", "pwsh"]:
    args = @["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
      "-Command", line]
  elif base == "cmd":
    args = @["/c", line]
  else:
    args = @["-c", line]
  try:
    var p = startProcess(shell, args = args,
      options = {poParentStreams, poUsePath})
    result = p.waitForExit()
    p.close()
  except OSError as e:
    stderr.writeLine("nish: cannot run " & shell & ": " & e.msg)
    result = 127
  finally:
    resumeAfterExec()
    discard takeCtrlC() # SIGINT that killed the child must not abort next line

proc expandPath(s: string): string =
  if s.startsWith("~"):
    getHomeDir() & s[1 .. ^1]
  else:
    s

proc runLine*(line: string, hist: var History,
    cfg: Config): tuple[code: int, shouldExit: bool] =
  # bash aliases only make sense for bash; nish.yaml aliases always apply
  let sys = if extractFilename(shellName()) == "bash": systemAliases()
    else: initTable[string, string]()
  let expanded = expandAliases(line, cfg.aliases, sys)
  let parts = expanded.splitWhitespace()
  if parts.len == 0:
    return (0, false)
  case parts[0]
  of "exit", "logout":
    var code = 0
    if parts.len > 1:
      try:
        code = parseInt(parts[1])
      except ValueError:
        stderr.writeLine("nish: exit: numeric argument required")
        code = 2
    return (code, true)
  of "cd":
    var target = if parts.len > 1: parts[1] else: getHomeDir()
    if target == "-":
      target = getEnv("OLDPWD", getCurrentDir())
      echo target
    target = expandPath(target)
    try:
      let old = getCurrentDir()
      setCurrentDir(target)
      putEnv("OLDPWD", old)
      putEnv("PWD", getCurrentDir())
      return (0, false)
    except OSError:
      stderr.writeLine("nish: cd: no such directory: " & target)
      return (1, false)
  of "export":
    for a in parts[1 .. ^1]:
      let eq = a.find('=')
      if eq > 0:
        putEnv(a[0 ..< eq], a[eq + 1 .. ^1])
      else:
        putEnv(a, "")
    return (0, false)
  of "unset":
    for a in parts[1 .. ^1]:
      delEnv(a)
    return (0, false)
  of "history":
    if parts.len > 1 and parts[1] == "-c":
      hist.clear()
      return (0, false)
    let n = min(hist.len, 50)
    for i in (hist.len - n) ..< hist.len:
      echo "  " & $(i + 1) & "  " & hist.items[i]
    return (0, false)
  of "clear":
    stdout.write("\e[2J\e[H")
    stdout.flushFile()
    return (0, false)
  of "help":
    echo "nish builtins: cd, exit, export, unset, history [-c], clear, help"
    echo "everything else runs via: " & shellName() & " (" &
      (if shellBase() in ["powershell", "pwsh"]: "-Command <line>"
       elif shellBase() == "cmd": "/c <line>"
       else: "-c <line>") & ")"
    echo "first-word aliases from ~/.bashrc, ~/.bash_aliases and nish.yaml apply (bash only)"
    echo "keys: type to filter (Enter runs typed line), Up/Down browse & edit," &
      " Tab completes path (repeat to cycle), Ctrl+Left/Right or Ctrl+</>" &
      " jump word, Esc dismisses"
    return (0, false)
  else:
    return (runPassthrough(expanded), false)
