REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
PATH="${REPO_ROOT}/tests/mocks:${PATH}"
source "${REPO_ROOT}/lib/common.sh"
source "${REPO_ROOT}/config.env"
