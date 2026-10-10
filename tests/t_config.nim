import os, strutils, tables
import ../src/config
import ../src/history

let base = getTempDir() / ("nish_cfg_" & $getCurrentProcessId())
createDir(base)

# missing file -> defaults
block:
  let c = loadConfig(base / "nope.yaml")
  assert c.historyFile == historyPath()
  assert c.historyMax == 10_000
  assert c.suggestCount == 6
  assert c.powerline

# full custom file
block:
  let p = base / "full.yaml"
  writeFile(p, "history_file: " & base / "h\nhistory_max: 500\n" &
    "suggest_count: 3\npowerline: false\n")
  let c = loadConfig(p)
  assert c.historyFile == base / "h", c.historyFile
  assert c.historyMax == 500
  assert c.suggestCount == 3
  assert not c.powerline

# partial file -> mixed with defaults; quoted colon value; string bool
block:
  let p = base / "partial.yaml"
  writeFile(p, "# comment\nsuggest_count: 9\npowerline: \"off\"\n")
  let c = loadConfig(p)
  assert c.suggestCount == 9
  assert not c.powerline
  assert c.historyMax == 10_000

# wrong types -> per-key fallback
block:
  let p = base / "types.yaml"
  writeFile(p, "history_max: abc\nsuggest_count: [1, 2]\npowerline: 42\n")
  let c = loadConfig(p)
  assert c.historyMax == 10_000
  assert c.suggestCount == 6
  assert c.powerline

# clamps
block:
  let p = base / "clamp.yaml"
  writeFile(p, "history_max: 5\nsuggest_count: 99\n")
  let c = loadConfig(p)
  assert c.historyMax == 100, $c.historyMax
  assert c.suggestCount == 20, $c.suggestCount

# broken yaml -> defaults, no crash
block:
  let p = base / "broken.yaml"
  writeFile(p, "history_max: [unclosed\n  bad indent:\n:")
  let c = loadConfig(p)
  assert c.historyMax == 10_000
  assert c.suggestCount == 6

# tilde + XDG path helper
block:
  assert configPath().endsWith("nish.yaml")
  let p = base / "tilde.yaml"
  writeFile(p, "history_file: \"~/my hist\"\n")
  let c = loadConfig(p)
  assert c.historyFile == getHomeDir() / "my hist", c.historyFile

# aliases mapping (strings kept, non-strings ignored)
block:
  let p = base / "aliases.yaml"
  writeFile(p, "aliases:\n  ll: 'ls -l'\n  g: git\n  bad: [1, 2]\n")
  let c = loadConfig(p)
  assert c.aliases["ll"] == "ls -l"
  assert c.aliases["g"] == "git"
  assert "bad" notin c.aliases

removeDir(base)
echo "t_config OK"
