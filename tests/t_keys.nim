import ../src/editor

# C0 bytes
block:
  assert c0Kind(0x09) == kkTab
  assert c0Kind(0x0D) == kkEnter
  assert c0Kind(0x7F) == kkBackspace
  assert c0Kind(0x08) == kkBackspace
  assert c0Kind(0x15) == kkCtrlU
  assert c0Kind(0x17) == kkCtrlW
  assert c0Kind(0x04) == kkCtrlD
  assert c0Kind(0x03) == kkCtrlC
  assert c0Kind(0x1C) == kkWordLeft # Ctrl+\ / Ctrl+<
  assert c0Kind(0x1E) == kkWordRight # Ctrl+>
  assert c0Kind(0x07) == kkNone
  assert c0Kind(0x1D) == kkNone

# CSI sequences
block:
  assert csiKind("", 'A') == kkUp
  assert csiKind("", 'B') == kkDown
  assert csiKind("", 'C') == kkRight
  assert csiKind("", 'D') == kkLeft
  assert csiKind("", 'H') == kkHome
  assert csiKind("", 'F') == kkEnd
  assert csiKind("3", '~') == kkDelete
  assert csiKind("1", '~') == kkHome
  assert csiKind("4", '~') == kkEnd
  assert csiKind("1;5", 'C') == kkWordRight # Ctrl+Right
  assert csiKind("1;5", 'D') == kkWordLeft # Ctrl+Left
  assert csiKind("1;3", 'C') == kkWordRight # Alt+Right
  assert csiKind("1;3", 'D') == kkWordLeft # Alt+Left
  assert csiKind("1;5", 'A') == kkUp
  assert csiKind("27;5;60", '~') == kkWordLeft # modifyOtherKeys Ctrl+<
  assert csiKind("27;5;62", '~') == kkWordRight # modifyOtherKeys Ctrl+>
  assert csiKind("2", '~') == kkNone
  assert csiKind("", 'Z') == kkNone
  assert csiKind("9;9", 'X') == kkNone

# word jumps are space-delimited, land on word starts
block:
  assert wordLeftFrom("hello world", 11) == 6
  assert wordLeftFrom("hello world", 6) == 0
  assert wordLeftFrom("hello world", 5) == 0
  assert wordLeftFrom("hello world", 0) == 0
  assert wordLeftFrom("  ab  ", 6) == 2
  assert wordLeftFrom("", 0) == 0
  assert wordRightFrom("hello world", 0) == 6
  assert wordRightFrom("hello world", 5) == 6
  assert wordRightFrom("hello world", 6) == 11
  assert wordRightFrom("hello world", 11) == 11
  assert wordRightFrom("ab  cd", 0) == 4
  assert wordRightFrom("", 0) == 0

# 7-bit dispatch boundary: DEL is Backspace, not text
block:
  assert asciiKind(0x1F) == c0Kind(0x1F)
  assert asciiKind(0x20) == kkText
  assert asciiKind(0x7E) == kkText
  assert asciiKind(0x7F) == kkBackspace
  assert asciiKind(0x00) == kkNone

echo "t_keys OK"
