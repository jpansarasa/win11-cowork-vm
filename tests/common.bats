setup() { load "test_helper"; }

@test "cpu_has_virt detects vmx" {
  run cpu_has_virt "flags: fpu vme vmx lm"
  [ "$status" -eq 0 ]
}

@test "cpu_has_virt detects svm" {
  run cpu_has_virt "flags: fpu svm lm"
  [ "$status" -eq 0 ]
}

@test "cpu_has_virt fails when absent" {
  run cpu_has_virt "flags: fpu vme lm"
  [ "$status" -ne 0 ]
}

@test "need_cmd dies on missing command" {
  run need_cmd definitely-not-a-real-binary-xyz
  [ "$status" -ne 0 ]
}
