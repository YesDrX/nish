import ../src/search
import ../src/history

# ranking: prefix > substring > fuzzy, most-recent-first on ties
block:
  var h = History(items: @[], lower: @[], cap: 100, path: "")
  for c in ["git status", "git commit -m x", "ls -la", "nim c -r main",
      "git push"]:
    h.items.add(c)
    h.lower.add(c)
  let r = filterHistory(h, "git", 6)
  assert r.len == 3, "expected 3 git matches, got " & $r.len
  assert r[0] == "git push", "most recent first, got " & r[0]

# empty query -> most recent, deduped
block:
  var h = History(items: @[], lower: @[], cap: 100, path: "")
  for c in ["a", "b", "a", "c"]:
    h.items.add(c)
    h.lower.add(c)
  let r = filterHistory(h, "", 6)
  assert r == @["c", "a", "b"], "dedup newest-wins failed: " & $r

# prefix ties -> most recent wins (not shortest)
block:
  var h = History(items: @[], lower: @[], cap: 100, path: "")
  for c in ["echo hello-nish", "echo piped | tr a-z A-Z"]:
    h.items.add(c)
    h.lower.add(c)
  let r = filterHistory(h, "echo", 6)
  assert r[0] == "echo piped | tr a-z A-Z", "recency must win ties, got " & r[0]

# substring beats fuzzy; fuzzy still finds subsequence; junk never matches
block:
  assert matchScore("ls", "ls -la") > matchScore("ls", "also here")
  assert matchScore("gp", "git push") >= 0
  assert matchScore("xyz", "git push") < 0

echo "t_search OK"
