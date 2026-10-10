## config.nim - ~/.config/nish.yaml loading with safe defaults.
##
## All keys optional; a missing file means defaults. A broken file also
## means defaults (plus one stderr warning, never a crash). Each present
## key is validated and clamped; bad values fall back per-key.

import os, strutils, json, tables
import yaml/tojson
import history

const
  DefaultSuggestCount* = 6
  MinHistoryMax = 100
  MaxHistoryMax = 1_000_000
  MinSuggestCount = 1
  MaxSuggestCount = 20

type
  Config* = object
    historyFile*: string
    historyMax*: int
    suggestCount*: int
    powerline*: bool
    aliases*: Table[string, string] ## nish.yaml aliases, win over bash ones

proc defaultConfig*(): Config =
  Config(historyFile: historyPath(), historyMax: DefaultHistoryCap,
    suggestCount: DefaultSuggestCount, powerline: true,
    aliases: initTable[string, string]())

proc configPath*(): string =
  ## $XDG_CONFIG_HOME/nish.yaml, else ~/.config/nish.yaml.
  let base = getEnv("XDG_CONFIG_HOME", "")
  let dir = if base != "": base else: getHomeDir() / ".config"
  dir / "nish.yaml"

proc expandTilde(s: string): string =
  if s == "~":
    getHomeDir()
  elif s.startsWith("~/"):
    getHomeDir() / s[2 .. ^1]
  else:
    s

proc asInt(node: JsonNode): tuple[ok: bool, val: int] =
  case node.kind:
  of JInt: (ok: true, val: node.getInt())
  of JFloat: (ok: true, val: int(node.getFloat()))
  of JString:
    try: (ok: true, val: parseInt(node.getStr().strip()))
    except ValueError: (ok: false, val: 0)
  else: (ok: false, val: 0)

proc asBool(node: JsonNode): tuple[ok: bool, val: bool] =
  case node.kind:
  of JBool: (ok: true, val: node.getBool())
  of JString:
    case node.getStr().strip().toLowerAscii():
    of "true", "yes", "1", "on": (ok: true, val: true)
    of "false", "no", "0", "off": (ok: true, val: false)
    else: (ok: false, val: false)
  else: (ok: false, val: false)

proc loadConfig*(path = ""): Config =
  result = defaultConfig()
  let p = if path == "": configPath() else: path
  if not fileExists(p):
    return result
  var content: string
  try:
    content = readFile(p)
  except IOError:
    return result
  var docs: seq[JsonNode]
  try:
    docs = loadToJson(content)
  except YamlParserError, YamlConstructionError:
    stderr.writeLine("nish: ignoring invalid config " & p & " (using defaults)")
    return result
  if docs.len == 0 or docs[0].kind != JObject:
    return result
  let root = docs[0]
  if root.hasKey("history_file") and root["history_file"].kind == JString:
    let v = expandTilde(root["history_file"].getStr().strip())
    if v != "":
      result.historyFile = v
  if root.hasKey("history_max"):
    let (ok, v) = asInt(root["history_max"])
    if ok:
      result.historyMax = clamp(v, MinHistoryMax, MaxHistoryMax)
  if root.hasKey("suggest_count"):
    let (ok, v) = asInt(root["suggest_count"])
    if ok:
      result.suggestCount = clamp(v, MinSuggestCount, MaxSuggestCount)
  if root.hasKey("powerline"):
    let (ok, v) = asBool(root["powerline"])
    if ok:
      result.powerline = v
  if root.hasKey("aliases") and root["aliases"].kind == JObject:
    for k, v in root["aliases"].fields:
      if v.kind == JString:
        result.aliases[k] = v.getStr()
