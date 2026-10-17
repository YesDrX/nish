import os, strutils, sequtils
import ../src/complete

let base = getTempDir() / ("nish_complete_" & $getCurrentProcessId())
let tree = base / "tree"
createDir(tree / "alpine" / "inner")
writeFile(tree / "alpha.txt", "x")
writeFile(tree / "beta", "x")
writeFile(tree / ".hidden", "x")
writeFile(tree / "alpine" / "inner.txt", "x")
writeFile(tree / "alpine" / "MiXeD.txt", "x")
let bin = base / "bin"
createDir(bin)
when defined(windows):
  writeFile(bin / "mycmd.exe", "x")
  writeFile(bin / "readme.txt", "x")
else:
  writeFile(bin / "mycmd", "#!/bin/sh\n")
  writeFile(bin / "readme", "x")
when defined(posix):
  setFilePermissions(bin / "mycmd",
    {fpUserExec, fpUserRead, fpGroupRead, fpOthersRead})

# path prefix: dirs first (trailing /), then files, alphabetical
block:
  let c = pathCandidates(tree / "al")
  assert c == @[tree / "alpine/", tree / "alpha.txt"], "got " & $c

# single exact dir
block:
  let c = pathCandidates(tree / "alpine")
  assert c == @[tree / "alpine/"], "got " & $c

# matching is case-insensitive, replacements keep on-disk case
block:
  assert pathCandidates(tree / "AL") ==
    @[tree / "alpine/", tree / "alpha.txt"], "got " & $(pathCandidates(tree / "AL"))
  let sub = tree / "alpine"
  assert pathCandidates(sub / "mix") == @[sub / "MiXeD.txt"]
  assert pathCandidates(sub / "MIX") == @[sub / "MiXeD.txt"]

# dotfiles only on dotted base
block:
  when defined(windows):
    assert pathCandidates(tree / ".h").mapIt(
      it.split({'/', '\\'})[^1]) == @[".hidden"]
  else:
    assert pathCandidates(tree / ".h").mapIt(it.split('/')[^1]) == @[".hidden"]
  assert pathCandidates(tree / "").mapIt(it.split('/')[^1]).filterIt(
    it.startsWith(".")) == @[]

# relative: cd into tree
block:
  let old = getCurrentDir()
  setCurrentDir(tree)
  assert pathCandidates("be") == @["beta"]
  assert pathCandidates("") == @["alpine" & $DirSep, "alpha.txt", "beta"]
  setCurrentDir(old)

# no match
block:
  assert pathCandidates(tree / "zzz-nope") == @[]

# commands: PATH exes + builtins, non-exec excluded (case-insensitive)
block:
  when defined(windows):
    let c = commandCandidates("m", bin)
    assert "mycmd.exe" in c, "got " & $c
    assert "readme.txt" notin c
    assert commandCandidates("M", bin) == @["mycmd.exe"]
  else:
    let c = commandCandidates("m", bin)
    assert "mycmd" in c, "got " & $c
    assert "readme" notin c
    assert commandCandidates("M", bin) == @["mycmd"], "got " &
      $commandCandidates("M", bin)
  assert "history" in commandCandidates("hi", bin)
  assert "history" in commandCandidates("HI", bin)

# dispatch
block:
  when defined(windows):
    assert completeCandidates("my", true, bin) == @["mycmd.exe"]
  else:
    assert completeCandidates("my", true, bin) == @["mycmd"]
  assert completeCandidates(tree / "al", true) ==
    @[tree / "alpine/", tree / "alpha.txt"]
  assert completeCandidates("be", false) == pathCandidates("be")

# command position
block:
  assert isCommandPosition("", 0)
  assert isCommandPosition("ls | gre", 5)
  assert not isCommandPosition("ls gre", 3)

removeDir(base)
echo "t_complete OK"
