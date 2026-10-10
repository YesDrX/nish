import os, tables
import ../src/alias

proc T(pairs: openArray[(string, string)]): Table[string, string] =
  result = initTable[string, string]()
  for (k, v) in pairs:
    result[k] = v

# parsing
block:
  let t = parseAliasText("""
# comment
alias ll='ls -l'
alias la="ls -A"
alias h=history
alias spaced = 'echo hi' # trailing
alias bare
alias novalue=
alias with_eq='a=b'
alias dup='one'
alias dup='two'
notanalias=x
""")
  assert t["ll"] == "ls -l", $t
  assert t["la"] == "ls -A"
  assert t["h"] == "history"
  assert t["spaced"] == "echo hi", "[" & t["spaced"] & "]"
  assert "bare" notin t
  assert t["novalue"] == ""
  assert t["with_eq"] == "a=b"
  assert t["dup"] == "two"
  assert "notanalias" notin t

# expansion basics
block:
  let sys = T({"ll": "ls -l", "g": "git"})
  let noExtra = initTable[string, string]()
  assert expandAliases("ll /tmp", noExtra, sys) == "ls -l /tmp"
  assert expandAliases("g status", noExtra, sys) == "git status"
  assert expandAliases("ls /tmp", noExtra, sys) == "ls /tmp"
  assert expandAliases("", noExtra, sys) == ""
  assert expandAliases("   ", noExtra, sys) == "   "
  assert expandAliases("'ll'", noExtra, sys) == "'ll'"
  assert expandAliases("\"ll\"", noExtra, sys) == "\"ll\""
  assert expandAliases("  ll  x", noExtra, sys) == "  ls -l  x"

# config (extra) wins over bash (sys)
block:
  let sys = T({"ll": "ls -l"})
  let extra = T({"ll": "ls -la"})
  assert expandAliases("ll", extra, sys) == "ls -la"

# recursion / cycles terminate
block:
  let sys = T({"a": "b", "b": "a", "s": "s"})
  let noExtra = initTable[string, string]()
  assert expandAliases("a x", noExtra, sys) == "b x"
  assert expandAliases("s x", noExtra, sys) == "s x"

# trailing-space chain (sudo-style)
block:
  let sys = T({"sudo": "sudo ", "ll": "ls -l"})
  let noExtra = initTable[string, string]()
  assert expandAliases("sudo ll /t", noExtra, sys) == "sudo ls -l /t"
  assert expandAliases("sudo ls", noExtra, sys) == "sudo ls"

# backslash-escaped first word bypasses (bash-like)
block:
  let sys = T({"ll": "ls -l"})
  let noExtra = initTable[string, string]()
  assert expandAliases("\\ll", noExtra, sys) == "\\ll"

# file loading: later files win, missing files ignored
block:
  let dir = getTempDir() / ("nish_alias_" & $getCurrentProcessId())
  createDir(dir)
  writeFile(dir / "a", "alias x='one'\nalias y='keep'\n")
  writeFile(dir / "b", "alias x='two'\n")
  let t = loadAliasFiles(@[dir / "a", dir / "b", dir / "missing"])
  assert t["x"] == "two"
  assert t["y"] == "keep"
  removeDir(dir)

# systemAliases never crashes, returns a table
block:
  discard systemAliases()

echo "t_alias OK"
