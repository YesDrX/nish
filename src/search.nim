## search.nim - fast in-memory history ranking.
##
## 10k entries need no index structure (trie/BK-tree overkill): a single
## linear scan with early-exit scoring is ~1ms in Nim. Lowercase candidates
## are precomputed once at history load; the query is lowered once per
## keystroke. Results are most-recent-first, deduped (newest wins).
##
## Ranking: prefix match > substring match (earlier pos wins) >
## subsequence-fuzzy match (fewer gaps wins).

import strutils, algorithm, sets
import history

proc matchScore*(query, candLower: string): int =
  ## Both args must already be lowercase. Returns -1 on no match.
  ## Class only depends on match kind; recency breaks ties in filterHistory.
  if query.len == 0:
    return 0
  if candLower.startsWith(query):
    return 1000
  let pos = candLower.find(query)
  if pos >= 0:
    return 500 - min(pos, 400)
  var qi = 0
  var gaps = 0
  var last = -1
  for i in 0 ..< candLower.len:
    if qi < query.len and candLower[i] == query[qi]:
      if last >= 0:
        gaps += i - last - 1
      last = i
      inc qi
      if qi == query.len:
        break
  if qi == query.len:
    return 100 - min(gaps, 90)
  return -1

proc filterHistory*(h: History, query: string, limit = 6): seq[string] =
  ## Top `limit` suggestions for `query`, most-recent-first, deduped.
  let q = query.toLowerAscii()
  if q.len == 0:
    var seen = initHashSet[string]()
    for i in countdown(h.items.high, 0):
      if h.items[i] notin seen:
        seen.incl(h.items[i])
        result.add(h.items[i])
        if result.len >= limit:
          break
    return
  var scored: seq[(int, int)] = @[]
  for i in 0 ..< h.items.len:
    let sc = matchScore(q, h.lower[i])
    if sc >= 0:
      scored.add((sc, i))
  scored.sort(proc(a, b: (int, int)): int =
    if a[0] != b[0]: cmp(b[0], a[0]) else: cmp(b[1], a[1]))
  var seen = initHashSet[string]()
  for (_, i) in scored:
    if h.items[i] notin seen:
      seen.incl(h.items[i])
      result.add(h.items[i])
      if result.len >= limit:
        break
