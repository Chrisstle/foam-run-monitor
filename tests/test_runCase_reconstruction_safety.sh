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
if [[ "${STUB_SOLVER_FAIL:-false}" == "true" ]]; then
    exit 1
fi
if [[ -n "${STUB_SOLVER_DELAY_DIR:-}" \
    && "$(basename "$PWD")" == "$STUB_SOLVER_DELAY_DIR" ]]; then
    [[ -n "${STUB_SOLVER_STARTED:-}" ]] && touch "$STUB_SOLVER_STARTED"
    sleep 2
fi
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
while IFS= read -r timeName; do
    if [[ "$timeName" =~ ^[+-]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][+-]?[0-9]+)?$ ]] \
        && ! [[ "$timeName" =~ ^[+-]?(0+([.]0*)?|[.]0+)([eE][+-]?[0-9]+)?$ ]]; then
        echo "$timeName"
    fi
done < <(find . -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V)
exit 0
EOF

    cat > "$stubDir/reconstructPar" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-help" ]]; then
    [[ "${STUB_NO_ALL_REGIONS:-false}" == "true" ]] || echo '  -allRegions  Use all regions'
    exit 0
fi
allRegions=false
for arg in "$@"; do
    [[ "$arg" == "-allRegions" ]] && allRegions=true
done
if [[ "${STUB_RECONSTRUCT_MODE:-complete}" == "complete" ]]; then
    mkdir -p 1
    if [[ -f processor0/1/U ]]; then
        cp processor0/1/U 1/U
    elif [[ -f processor0/1/fluid/U && "$allRegions" == true ]]; then
        mkdir -p 1/fluid
        cp processor0/1/fluid/U 1/fluid/U
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

    cat > "$stubDir/reconstructParMesh" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-help" ]]; then
    [[ "${STUB_NO_ALL_REGIONS:-false}" == "true" ]] || echo '  -allRegions  Use all regions'
    exit 0
fi
allRegions=false
for arg in "$@"; do
    [[ "$arg" == "-allRegions" ]] && allRegions=true
done
if [[ -f constant/regionProperties && "$allRegions" != true ]]; then
    exit 1
fi
echo 'End'
exit 0
EOF

    cat > "$stubDir/checkMesh" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-help" ]]; then
    [[ "${STUB_NO_CHECKMESH_ALL_REGIONS:-false}" == "true" ]] \
        || echo '  -allRegions  Use all regions'
    echo '  -region name  Use specified region'
    exit 0
fi
if [[ "${STUB_CHECK_MESH_FAIL:-false}" == "true" ]]; then
    echo 'FOAM FATAL ERROR'
    exit 1
fi
echo 'Mesh OK.'
exit 0
EOF

    cat > "$stubDir/setFields" <<'EOF'
#!/bin/bash
exit 0
EOF

    cat > "$stubDir/animateCase" <<'EOF'
#!/bin/bash
for arg in "$@"; do
    caseDir="$arg"
done
caseName=$(basename "$caseDir")
touch "$caseDir/${caseName}.avi"
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
    elif [[ "$layout" == "multi-region" ]]; then
        cat > "$caseDir/constant/regionProperties" <<'EOF'
regions (fluid solid);
EOF
        mkdir -p "$caseDir/constant/fluid/polyMesh" \
            "$caseDir/constant/solid/polyMesh"
        cat > "$caseDir/constant/fluid/dynamicMeshDict" <<'EOF'
dynamicFvMesh dynamicMotionSolverFvMesh;
EOF
        make_foam_file "$caseDir/processor0/1/fluid/U" volScalarField
        make_foam_file "$caseDir/processor1/1/fluid/U" volScalarField
    else
        make_foam_file "$caseDir/processor0/1/U" volScalarField
        make_foam_file "$caseDir/processor1/1/U" volScalarField
    fi
}

make_serial_case() {
    local caseDir="$1"

    mkdir -p "$caseDir/system" "$caseDir/constant"
    cat > "$caseDir/system/controlDict" <<'EOF'
application testSolver;
endTime 1;
writeInterval 1;
EOF
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

multiRegionCase="$testRoot/multi-region"
make_case "$multiRegionCase" multi-region
STUB_RECONSTRUCT_MODE=complete STUB_NO_CHECKMESH_ALL_REGIONS=true \
    run_case "$multiRegionCase" "$stubDir" \
    > "$testRoot/multi-region.out"
assert_missing "$multiRegionCase/processor0"
assert_missing "$multiRegionCase/processor1"
assert_exists "$multiRegionCase/1/fluid/U"
assert_contains 'Reconstructed data verified' "$testRoot/multi-region.out"

unsupportedRegionsCase="$testRoot/unsupported-regions"
make_case "$unsupportedRegionsCase" multi-region
STUB_NO_ALL_REGIONS=true run_case "$unsupportedRegionsCase" "$stubDir" \
    > "$testRoot/unsupported-regions.out" || true
assert_exists "$unsupportedRegionsCase/processor0"
assert_exists "$unsupportedRegionsCase/processor1"
assert_contains 'cannot reconstruct all regions safely' "$testRoot/unsupported-regions.out"

cleanupCase="$testRoot/exact-cleanup"
make_case "$cleanupCase"
mkdir "$cleanupCase/processorBackup" "$cleanupCase/processor0.old" \
    "$cleanupCase/processors_archive"
(
    cd "$cleanupCase"
    PATH="$stubDir:$PATH" TERM=xterm ./runCase -clean -q
) > "$testRoot/exact-cleanup.out"
assert_missing "$cleanupCase/processor0"
assert_missing "$cleanupCase/processor1"
assert_exists "$cleanupCase/processorBackup"
assert_exists "$cleanupCase/processor0.old"
assert_exists "$cleanupCase/processors_archive"

scientificCase="$testRoot/scientific-time"
mkdir -p "$scientificCase/system" "$scientificCase/constant" \
    "$scientificCase/1e-06" "$scientificCase/2E+06" "$scientificCase/-1"
cat > "$scientificCase/system/controlDict" <<'EOF'
application testSolver;
endTime 1;
writeInterval 1;
EOF
if printf 'n\n' | (
    cd "$testRoot"
    PATH="$stubDir:$PATH" TERM=xterm "$repoDir/runCase" --new "$scientificCase"
) > "$testRoot/scientific-time.out" 2>&1; then
    echo "Expected scientific-time cleanup confirmation to be declined" >&2
    exit 1
fi
assert_exists "$scientificCase/1e-06"
assert_exists "$scientificCase/2E+06"
assert_exists "$scientificCase/-1"
assert_contains 'Existing simulation data detected' "$testRoot/scientific-time.out"

queuedCase="$testRoot/queued-data"
make_case "$queuedCase"
if (
    cd "$queuedCase"
    PATH="$stubDir:$PATH" TERM=xterm ./runCase --batch-new-if-empty -q
) > "$testRoot/queued-data.out" 2>&1; then
    echo "Expected queued case with unapproved data to abort" >&2
    exit 1
fi
assert_exists "$queuedCase/processor0"
assert_contains 'Unapproved simulation data appeared' "$testRoot/queued-data.out"

runningBatchCase="$testRoot/a-running"
queuedBatchCase="$testRoot/b-queued"
make_serial_case "$runningBatchCase"
make_serial_case "$queuedBatchCase"
(
    printf 'y\n' | STUB_SOLVER_DELAY_DIR=a-running \
        STUB_SOLVER_STARTED="$testRoot/solver-started" \
        PATH="$stubDir:$PATH" TERM=xterm "$repoDir/runCase" \
        --new --quiet -P 1 "$runningBatchCase" "$queuedBatchCase"
) > "$testRoot/batch-race.out" 2>&1 &
batchPid=$!
for unused in {1..50}; do
    [[ -e "$testRoot/solver-started" ]] && break
    sleep 0.1
done
if [[ ! -e "$testRoot/solver-started" ]]; then
    echo "Timed out waiting for the first batch worker" >&2
    exit 1
fi
mkdir "$queuedBatchCase/1e-06"
wait "$batchPid"
assert_exists "$queuedBatchCase/1e-06"
assert_contains 'Unapproved simulation data appeared' \
    "$queuedBatchCase/log/.batch_worker.log"

animationCase="$testRoot/animation-case"
make_serial_case "$animationCase"
echo 'existing animation' > "$animationCase/animation-case_Crashed.avi"
printf 'y\n' | STUB_SOLVER_FAIL=true PATH="$stubDir:$PATH" TERM=xterm \
    "$repoDir/runCase" --continue --quiet --animate "$animationCase" \
    > "$testRoot/animation.out" 2>&1
assert_contains 'existing animation' "$animationCase/animation-case_Crashed.avi"
assert_exists "$animationCase/animation-case_Crashed_1.avi"

echo "runCase reconstruction safety tests passed"
