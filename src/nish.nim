## nish - nim shell.
## Colored powerline prompt, live history search dropdown (illwill),
## 10k ringbuffer history, everything else via bash.

import terminal, os, strutils
import prompt, history, editor, exec, config

const NishVersion = "0.1.0"

proc runBatch(hist: var History, cfg: Config): int =
  ## Non-tty stdin: run each line, no prompt/editor.
  result = 0
  for line in stdin.lines:
    if line.strip().len == 0:
      continue
    hist.add(line.strip())
    let (code, shouldExit) = runLine(line.strip(), hist, cfg)
    result = code
    if shouldExit:
      break

proc main(): int =
  let cfg = loadConfig()
  var hist = loadHistory(cfg.historyFile, cfg.historyMax)
  if not stdin.isatty or not stdout.isatty:
    return runBatch(hist, cfg)
  editorInit()
  defer:
    editorDeinit()
  echo "nish " & NishVersion &
    " - type to filter (Enter runs what you typed), Up/Down browse+edit," &
    " Tab completes paths, Ctrl+Left/Right or Ctrl+</> jump word," &
    " Esc dismisses"
  var lastExit = 0
  while true:
    let pr = buildPrompt(lastExit, usePowerline(cfg.powerline))
    let res = readLine(pr, hist, cfg)
    if res.eof:
      break
    if res.aborted:
      lastExit = 130
      continue
    let line = res.line.strip()
    if line.len == 0:
      continue
    hist.add(line)
    let (code, shouldExit) = runLine(line, hist, cfg)
    lastExit = code
    if shouldExit:
      result = code
      break

when isMainModule:
  quit(main())
