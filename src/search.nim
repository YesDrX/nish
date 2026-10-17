## search.nim - fast in-memory history ranking.
##
## 10k entries need no index structure (trie/BK-tree overkill): a single
## linear scan with early-exit scoring plus a bounded top-k selection is
## well under 1ms in release builds. Lowercase candidates are precomputed
## once at history load; the query is lowered once per keystroke. Results
## are most-recent-first, deduped (newest wins).
##
## Ranking: prefix match > substring match (earlier pos wins) >
## subsequence-fuzzy match (fewer gaps wins).

import strutils, sets
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
  ## Single newest-to-oldest pass with a bounded top-k list: identical
  ## results to scoring all + full sort + newest-wins dedup, but O(n*limit)
  ## with no per-keystroke sort or large temp allocations.
  let q = query.toLowerAscii()
  if q.len == 0 or limit <= 0:
    if q.len == 0 and limit > 0:
      var seen = initHashSet[string]()
      for i in countdown(h.items.high, 0):
        if h.items[i] notin seen:
          seen.incl(h.items[i])
          result.add(h.items[i])
          if result.len >= limit:
            break
    return
  var bestScores: seq[int] = @[] # desc; parallel to bestIdx
  var bestIdx: seq[int] = @[]
  var inBest = initHashSet[string]() # strings currently selected (<= limit)
  for i in countdown(h.items.high, 0):
    let sc = matchScore(q, h.lower[i])
    if sc < 0:
      continue
    if bestScores.len >= limit and sc <= bestScores[^1]:
      # Best is full and the newcomer ranks at/below the minimum:
      # equal scores keep their higher indices first (we scan newest to
      # oldest), so it would land last and be evicted — skip hashing.
      continue
    let s = h.items[i]
    if s in inBest:
      continue # newest occurrence already selected
    # Insert after all equal scores (older indices rank lower).
    var pos = 0
    while pos < bestScores.len and bestScores[pos] >= sc:
      inc pos
    bestScores.insert(sc, pos)
    bestIdx.insert(i, pos)
    inBest.incl(s)
    if bestScores.len > limit:
      inBest.excl(h.items[bestIdx[^1]])
      bestScores.setLen(limit)
      bestIdx.setLen(limit)
  for i in bestIdx:
    result.add(h.items[i])
