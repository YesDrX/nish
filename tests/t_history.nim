import os
import ../src/history

# ringbuffer eviction + file append + reload + consecutive-dedup
block:
  let dir = getTempDir() / ("nish_test_" & $getCurrentProcessId())
  createDir(dir)
  let p = dir / "hist"
  var h = loadHistory(p, cap = 5)
  assert h.len == 0
  h.add("")
  h.add("   ")
  assert h.len == 0, "empty lines must be skipped"
  h.add("a")
  h.add("a")
  assert h.len == 1, "consecutive dup must be skipped"
  for c in ["b", "c", "d", "e", "f"]:
    h.add(c)
  assert h.len == 5, "cap 5, got " & $h.len
  assert h.items[0] == "b", "oldest evicted, got " & h.items[0]
  var h2 = loadHistory(p, cap = 5)
  assert h2.items == h.items, "reload mismatch: " & $h2.items
  h2.clear()
  assert h2.len == 0 and getFileSize(p) == 0
  removeDir(dir)

# non-consecutive dup moves to newest, memory stays unique
block:
  let dir = getTempDir() / ("nish_dedup_" & $getCurrentProcessId())
  createDir(dir)
  let p = dir / "hist"
  var h = loadHistory(p, cap = 5)
  h.add("a")
  h.add("b")
  h.add("c")
  h.add("a")
  assert h.items == @["b", "c", "a"], "move-to-newest failed: " & $h.items
  assert h.lower == @["b", "c", "a"], "lower out of sync"
  var h2 = loadHistory(p, cap = 5)
  assert h2.items == @["b", "c", "a"], "reload dedup failed: " & $h2.items
  removeDir(dir)

echo "t_history OK"
