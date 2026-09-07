#!/bin/bash

set -eu

repoDir=$(cd "$(dirname "$0")/.." && pwd)
testRoot=$(mktemp -d)
cleanup() {
    local status=$?
    rm -rf -- "$testRoot"
    exit "$status"
}
trap cleanup EXIT

make_foam_file() {
    local path="$1"
    local className="$2"
    mkdir -p "$(dirname "$path")"
    {
        echo 'FoamFile'
        echo '{'
        echo "    class $className;"
        echo '    object U;'
        echo '}'
        echo 'internalField uniform 0;'
    } > "$path"
}

make_stubs() {
    local stubDir="$1"
    mkdir -p "$stubDir"

    cat > "$stubDir/testSolver" <<'EOF'
#!/bin/bash
exit 0
EOF

    cat > "$stubDir/foamListTimes" <<'EOF'
#!/bin/bash
for arg in "$@"; do
    if [[ "$arg" == "-processor" ]]; then
        echo 1
        exit 0
    fi
done
[[ -d 1 ]] && echo 1
exit 0
EOF

    cat > "$stubDir/reconstructPar" <<'EOF'
#!/bin/bash
if [[ "${STUB_RECONSTRUCT_MODE:-complete}" == "complete" ]]; then
    mkdir -p 1
    if [[ -f processor0/1/U ]]; then
        cp processor0/1/U 1/U
    else
        cat > 1/U <<'INNER'
FoamFile
{
    class volScalarField;
    object U;
}
internalField uniform 0;
INNER
    fi
elif [[ "${STUB_RECONSTRUCT_MODE:-complete}" == "wrong-class" ]]; then
    mkdir -p 1
    cat > 1/U <<'INNER'
FoamFile
{
    class volVectorField;
    object U;
}
internalField uniform (0 0 0);
INNER
fi
echo 'Time = 1'
if [[ "${STUB_RECONSTRUCT_MODE:-complete}" != "no-end" ]]; then
    echo 'End'
fi
EOF

    cat > "$stubDir/checkMesh" <<'EOF'
#!/bin/bash
if [[ "${STUB_CHECK_MESH_FAIL:-false}" == "true" ]]; then
    echo 'FOAM FATAL ERROR'
    exit 1
fi
echo 'Mesh OK.'
exit 0
EOF

    chmod +x "$stubDir"/*
}

make_case() {
    local caseDir="$1"
    local layout="${2:-uncollated}"

    mkdir -p "$caseDir/system" "$caseDir/constant"
    cp "$repoDir/runCase" "$caseDir/runCase"

    cat > "$caseDir/system/controlDict" <<'EOF'
application testSolver;
endTime 1;
writeInterval 1;
EOF

    cat > "$caseDir/system/decomposeParDict" <<'EOF'
numberOfSubdomains 2;
EOF

    if [[ "$layout" == "collated" ]]; then
        make_foam_file "$caseDir/processors2/1/U" decomposedBlockData
    else
        make_foam_file "$caseDir/processor0/1/U" volScalarField
        make_foam_file "$caseDir/processor1/1/U" volScalarField
    fi
}

run_case() {
    local caseDir="$1"
    local stubDir="$2"
    shift 2

    (
        cd "$caseDir"
        PATH="$stubDir:$PATH" TERM=xterm ./runCase -r -q "$@"
    )
}

assert_exists() {
    [[ -e "$1" ]] || {
        echo "Expected path to exist: $1" >&2
        exit 1
    }
}

assert_missing() {
    [[ ! -e "$1" ]] || {
        echo "Expected path to be absent: $1" >&2
        exit 1
    }
}

assert_contains() {
    local pattern="$1"
    local path="$2"
    if ! grep -q -- "$pattern" "$path"; then
        echo "Expected '$path' to contain: $pattern" >&2
        sed -n '1,240p' "$path" >&2
        exit 1
    fi
}

stubDir="$testRoot/stubs"
make_stubs "$stubDir"

completeCase="$testRoot/complete"
make_case "$completeCase"
mkdir "$completeCase/processorBackup"
STUB_RECONSTRUCT_MODE=complete run_case "$completeCase" "$stubDir" \
    > "$testRoot/complete.out"
assert_missing "$completeCase/processor0"
assert_missing "$completeCase/processor1"
assert_exists "$completeCase/processorBackup"
assert_contains 'Reconstructed data verified' "$testRoot/complete.out"

missingCase="$testRoot/missing"
make_case "$missingCase"
STUB_RECONSTRUCT_MODE=missing run_case "$missingCase" "$stubDir" \
    > "$testRoot/missing.out"
assert_exists "$missingCase/processor0"
assert_exists "$missingCase/processor1"
assert_contains 'verification failed' "$testRoot/missing.out"

staleCase="$testRoot/stale"
make_case "$staleCase"
make_foam_file "$staleCase/1/U" volScalarField
STUB_RECONSTRUCT_MODE=missing run_case "$staleCase" "$stubDir" \
    > "$testRoot/stale.out"
assert_exists "$staleCase/processor0"
assert_exists "$staleCase/processor1"
assert_contains 'was not refreshed' "$testRoot/stale.out"

keepCase="$testRoot/keep"
make_case "$keepCase"
STUB_RECONSTRUCT_MODE=complete run_case "$keepCase" "$stubDir" \
    --keep-processors > "$testRoot/keep.out"
assert_exists "$keepCase/processor0"
assert_exists "$keepCase/processor1"
assert_contains '--keep-processors' "$testRoot/keep.out"

collatedCase="$testRoot/collated"
make_case "$collatedCase" collated
STUB_RECONSTRUCT_MODE=complete run_case "$collatedCase" "$stubDir" \
    > "$testRoot/collated.out"
assert_missing "$collatedCase/processors2"
assert_contains 'Reconstructed data verified' "$testRoot/collated.out"

wrongClassCase="$testRoot/wrong-class"
make_case "$wrongClassCase"
STUB_RECONSTRUCT_MODE=wrong-class run_case "$wrongClassCase" "$stubDir" \
    > "$testRoot/wrong-class.out"
assert_exists "$wrongClassCase/processor0"
assert_exists "$wrongClassCase/processor1"
assert_contains 'class mismatch' "$testRoot/wrong-class.out"

noEndCase="$testRoot/no-end"
make_case "$noEndCase"
STUB_RECONSTRUCT_MODE=no-end run_case "$noEndCase" "$stubDir" \
    > "$testRoot/no-end.out"
assert_exists "$noEndCase/processor0"
assert_exists "$noEndCase/processor1"
assert_contains 'normal End marker' "$testRoot/no-end.out"

unreadableMeshCase="$testRoot/unreadable-mesh"
make_case "$unreadableMeshCase"
STUB_RECONSTRUCT_MODE=complete STUB_CHECK_MESH_FAIL=true \
    run_case "$unreadableMeshCase" "$stubDir" > "$testRoot/unreadable-mesh.out"
assert_exists "$unreadableMeshCase/processor0"
assert_exists "$unreadableMeshCase/processor1"
assert_contains 'checkMesh could not read' "$testRoot/unreadable-mesh.out"

echo "runCase reconstruction safety tests passed"
