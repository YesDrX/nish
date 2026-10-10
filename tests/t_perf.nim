import times, strutils
import ../src/search
import ../src/history

var h = History(items: @[], lower: @[], cap: 20000, path: "")
for i in 0 ..< 10_000:
  let c = case i mod 5
    of 0: "git commit -m msg" & $i
    of 1: "nim c -d:release src/module" & $i & ".nim"
    of 2: "echo hello world " & $i
    of 3: "ls -la /some/path/number" & $i
    else: "kubectl get pods -n ns" & $i
  h.items.add(c)
  h.lower.add(c.toLowerAscii())

for q in ["git", "nim", "xyz-nomatch", "get pods", "e"]:
  let t0 = cpuTime()
  var n = 0
  for _ in 0 ..< 50:
    n = filterHistory(h, q, 6).len
  let ms = (cpuTime() - t0) * 1000 / 50
  echo q, " -> ", n, " matches, ", formatFloat(ms, ffDecimal, 3), " ms/filter"

echo "t_perf OK"
