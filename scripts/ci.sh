#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/ci.sh [pr [<git-ref>]]  Run the test suite on the working tree or a local Git revision.
  scripts/ci.sh release <git-ref> Run the release test suite on a local Git revision.
EOF
}

mode=${1:-pr}
revision=${2:-}
case "$mode" in
    -h|--help) usage; exit 0 ;;
    pr|release) ;;
    *) usage >&2; exit 2 ;;
esac
if [[ $# -gt 2 || ( "$mode" == release && -z "$revision" ) ]]; then
    usage >&2
    exit 2
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
package_path=$root
if [[ -n "$revision" ]]; then
    commit=$(git -C "$root" rev-parse --verify --end-of-options "${revision}^{commit}")
    package_path=$(mktemp -d "${TMPDIR:-/tmp}/limb-ci.XXXXXXXX")
    trap 'rm -rf -- "$package_path"' EXIT
    git -C "$root" archive --format=tar "$commit" | tar -xf - -C "$package_path"
    printf 'Testing commit %s\n' "$commit"
else
    printf 'Testing the working tree at %s\n' "$root"
fi

swift --version

# The descriptor exhaustion tests must each run in their own process.
unset LIMB_INDEPENDENT_ISOLATED
run_tests() {
    swift test --package-path "$package_path" --no-parallel "$@"
}

run_isolated_stdio_tests() {
    local test_names test_name
    printf '\nIsolated stdio tests\n'
    test_names=$(swift test --package-path "$package_path" "$@" list --skip-build)
    for test_name in \
        whenTheWakeUpPipeCannotBeCreatedRunReturnsAndLeavesNothingBehind \
        whenTheOutputCannotBeDuplicatedRunDoesNotServe
    do
        if ! grep -Fq "$test_name(" <<< "$test_names"; then
            printf 'Required stdio test not found: %s\n' "$test_name" >&2
            return 1
        fi
        LIMB_INDEPENDENT_ISOLATED=1 run_tests "$@" --skip-build --filter "$test_name"
    done
}

if [[ "$mode" == release ]]; then
    printf '\nRelease tests with the default JSON codec\n'
    run_tests --configuration release
    run_isolated_stdio_tests --configuration release

    printf '\nRelease tests with FoundationJSON\n'
    run_tests --configuration release --traits FoundationJSON
else
    run_tests
    run_isolated_stdio_tests
fi
