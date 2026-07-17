setup() {
  load "test_helper"
  source "${REPO_ROOT}/lib/generators.sh"
  export MOCKLOG="$BATS_TMPDIR/mock.log"; : > "$MOCKLOG"
}

@test "preflight_check_virt fails when cpuinfo lacks vmx/svm" {
  echo "flags: fpu vme lm" > "$BATS_TMPDIR/cpuinfo"
  CPUINFO_FILE="$BATS_TMPDIR/cpuinfo" run bash -c \
    'source lib/common.sh; source scripts/00-preflight.sh; preflight_check_virt'
  [ "$status" -ne 0 ]
}

@test "preflight_check_virt passes with vmx and /dev/kvm" {
  echo "flags: fpu vmx lm" > "$BATS_TMPDIR/cpuinfo"
  CPUINFO_FILE="$BATS_TMPDIR/cpuinfo" KVM_DEV=/dev/null run bash -c \
    'source lib/common.sh; source scripts/00-preflight.sh; preflight_check_virt'
  [ "$status" -eq 0 ]
}
