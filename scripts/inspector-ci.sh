#!/bin/bash
set -euo pipefail

usage() {
    printf 'Usage: %s [<git-ref>]\n' "$0"
    printf '       %s --release <git-ref> <report.json>\n' "$0"
    printf 'Run MCP Inspector stdio compatibility checks on the working tree or a local Git revision.\n'
    printf 'Release mode adds sustained mixed load and writes a JSON report for the exact Git revision.\n'
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    usage
    exit 0
fi
report=
revision=${1:-}
if [[ "$revision" == --release && $# -eq 3 && -n "$2" && -n "$3" ]]; then
    revision=$2
    report=$3
    if [[ "$report" != /* ]]; then report=$PWD/$report; fi
    if [[ -e "$report" || -L "$report" ]]; then
        printf 'Report already exists: %s\n' "$report" >&2
        exit 1
    fi
elif [[ $# -gt 1 || "$revision" == --* ]]; then
    usage >&2
    exit 2
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/limb-inspector.XXXXXXXX")
stage=preparation
reporter=
finish() {
    local status=$?
    if [[ -n "$reporter" ]]; then
        if ! node "$reporter" "$scratch" "$report" "$commit" "$stage" "$status"; then
            if [[ "$status" == 0 ]]; then status=1; fi
        fi
    fi
    rm -rf -- "$scratch"
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

source_path=$root
if [[ -n "$revision" ]]; then
    commit=$(git -C "$root" rev-parse --verify --end-of-options "${revision}^{commit}")
    source_path=$scratch/source
    mkdir "$source_path"
    git -C "$root" archive --format=tar "$commit" | tar -xf - -C "$source_path"
    printf 'Testing commit %s\n' "$commit"
else
    printf 'Testing the working tree at %s\n' "$root"
fi

inspector_path=$source_path/Tests/Inspector
if [[ ! -f "$inspector_path/verify.mjs" || ! -f "$inspector_path/Fixture/Package.swift" ]]; then
    printf 'Inspector checks are not available in this snapshot.\n' >&2
    exit 1
fi

if [[ -n "$report" ]]; then
    if [[ ! -f "$inspector_path/release-report.mjs" ]]; then
        printf 'Inspector release checks are not available in this snapshot.\n' >&2
        exit 1
    fi
    mkdir -p -- "$(dirname -- "$report")" "$scratch/results"
    reporter=$inspector_path/release-report.mjs
fi

for tool in node npm swift; do
    if ! command -v "$tool" >/dev/null; then
        printf 'Required command not found: %s\n' "$tool" >&2
        exit 1
    fi
done

export MCP_STORAGE_DIR=$scratch/storage
export MCP_INSPECTOR_OAUTH_STATE_PATH=$MCP_STORAGE_DIR/oauth.json
mkdir "$MCP_STORAGE_DIR" "$scratch/client"
cp "$inspector_path/package.json" "$inspector_path/package-lock.json" \
    "$inspector_path/"*.mjs "$scratch/client/"

swift --version | tee "$scratch/swift-version.txt"
node --version
stage=dependencies
(
    cd "$scratch/client"
    npm ci --engine-strict --ignore-scripts --no-audit --no-fund
)

run_codec() {
    local codec=$1 stage_suffix=$2 binary_path actual_codec
    shift 2
    local build_options=(--package-path "$inspector_path/Fixture" --scratch-path "$scratch/build" --configuration release)
    stage=build_$stage_suffix
    swift build "${build_options[@]}" "$@" || return 1
    binary_path=$(swift build "${build_options[@]}" "$@" --show-bin-path)/LimbInspectorFixture || return 1
    actual_codec=$("$binary_path" --codec) || return 1
    if [[ "$actual_codec" != "$codec" ]]; then
        printf 'Expected %s codec, built %s\n' "$codec" "$actual_codec" >&2
        return 1
    fi
    stage=verify_$stage_suffix
    if [[ -n "$report" ]]; then
        node "$scratch/client/verify.mjs" "$binary_path" "$codec" "$scratch/results"
    else
        node "$scratch/client/verify.mjs" "$binary_path" "$codec"
    fi
}

if [[ -z "$report" ]]; then
    run_codec default default
    run_codec FoundationJSON foundation --traits FoundationJSON
else
    stage=preparation
    node --test "$scratch/client/"*.test.mjs
    failure_stage=
    run_codec default default || failure_stage=$stage
    run_codec FoundationJSON foundation --traits FoundationJSON || failure_stage=${failure_stage:-$stage}
    if [[ -n "$failure_stage" ]]; then
        stage=$failure_stage
        exit 1
    fi
    stage=complete
fi
