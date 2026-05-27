#!/bin/bash
set +e

OSS_FUZZ_DIR="/mnt/ssd/fuzzing/oss-fuzz-repo"
RESULTS_DIR="./results-draco"
RUN_DIR="./draco-fuzz-runs"
TSV_OUTPUT="./draco_cov.tsv"
MAX_PARALLEL=40
FUZZ_TIME=3600
PROJECT="draco"
TARGET_NAME="draco_pc_decoder_fuzzer"
TARGET_PATH="/src/draco/src/draco/tools/fuzz/draco_pc_decoder_fuzzer.cc"

mkdir -p "$RUN_DIR"

echo -e "benchmark_id\ttarget_function\tedge_cov\tcorpus_size\texecs\tstatus" > "$TSV_OUTPUT"

TARGETS=$(find "$RESULTS_DIR" -iname "0*.log" -path "*/run/*" | xargs dirname | sort -u | xargs -I{} dirname {} | xargs -I{} dirname {} | sort -u)

echo "=== Phase 1: Building fuzz drivers ==="
echo "Total targets: $(echo "$TARGETS" | wc -l)"

for output_dir in $TARGETS; do
    benchmark_id=$(basename "$output_dir" | sed 's/output-//')
    func_id=$(echo "$benchmark_id" | sed "s/^${PROJECT}-//" | sed 's/^_//')
    gen_project="${PROJECT}-${func_id}-rebuild"
    gen_project_short=$(echo "$gen_project" | cut -c1-80)
    out_dir="$OSS_FUZZ_DIR/build/out/$gen_project_short"
    binary="$out_dir/$TARGET_NAME"

    if [ -f "$binary" ]; then
        echo "SKIP (already built): $benchmark_id"
        continue
    fi

    fuzz_target_src="$output_dir/fuzz_targets/01.fuzz_target"
    if [ ! -f "$fuzz_target_src" ]; then
        echo "SKIP (no source): $benchmark_id"
        continue
    fi

    dst_project="$OSS_FUZZ_DIR/projects/$gen_project_short"
    rm -rf "$dst_project"
    cp -r "$OSS_FUZZ_DIR/projects/$PROJECT" "$dst_project"

    target_filename=$(basename "$TARGET_PATH")
    cp "$fuzz_target_src" "$dst_project/$target_filename"
    echo "COPY $target_filename $TARGET_PATH" >> "$dst_project/Dockerfile"

    if ! docker build -t "gcr.io/oss-fuzz/$gen_project_short" "$dst_project" > /dev/null 2>&1; then
        echo "FAIL (image build): $benchmark_id"
        rm -rf "$dst_project"
        continue
    fi

    mkdir -p "$out_dir"
    work_dir="$OSS_FUZZ_DIR/build/work/$gen_project_short"
    mkdir -p "$work_dir"

    if ! docker run --rm --privileged --shm-size=2g --platform linux/amd64 -i \
        -e FUZZING_ENGINE=libfuzzer \
        -e SANITIZER=address \
        -e ARCHITECTURE=x86_64 \
        -e "PROJECT_NAME=$gen_project_short" \
        -e FUZZING_LANGUAGE=c++ \
        -v "$out_dir:/out" \
        -v "$work_dir:/work" \
        --entrypoint /bin/bash \
        "gcr.io/oss-fuzz/$gen_project_short" \
        -c 'rm -rf /out/* /work/* && compile && chmod 777 -R /out/*' > /dev/null 2>&1; then
        echo "FAIL (compile): $benchmark_id"
        rm -rf "$dst_project"
        continue
    fi

    rm -rf "$dst_project"

    if [ -f "$binary" ]; then
        echo "OK: $benchmark_id"
    else
        echo "FAIL (no binary): $benchmark_id"
    fi

    docker container prune -f > /dev/null 2>&1
    docker image prune -f > /dev/null 2>&1
done

echo ""
echo "=== Phase 2: Running fuzz drivers (max $MAX_PARALLEL parallel, ${FUZZ_TIME}s each) ==="

run_fuzzer() {
    local output_dir="$1"
    local benchmark_id=$(basename "$output_dir" | sed 's/output-//')
    local func_id=$(echo "$benchmark_id" | sed "s/^${PROJECT}-//" | sed 's/^_//')
    local gen_project="${PROJECT}-${func_id}-rebuild"
    local gen_project_short=$(echo "$gen_project" | cut -c1-80)
    local binary="$OSS_FUZZ_DIR/build/out/$gen_project_short/$TARGET_NAME"
    local corpus_dir=$(find "$output_dir/corpora" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
    local run_log="$RUN_DIR/${benchmark_id}.log"

    if [ ! -f "$binary" ]; then
        echo -e "${benchmark_id}\t-\t0\t0\t0\tbuild_failed" >> "$TSV_OUTPUT"
        return
    fi

    local fuzz_corpus="$RUN_DIR/${benchmark_id}_corpus"
    mkdir -p "$fuzz_corpus"
    if [ -n "$corpus_dir" ] && [ -d "$corpus_dir" ]; then
        cp "$corpus_dir"/* "$fuzz_corpus/" 2>/dev/null || true
    fi

    local corpus_size=$(find "$fuzz_corpus" -type f | wc -l)

    timeout $((FUZZ_TIME + 30)) "$binary" "$fuzz_corpus" \
        -max_total_time=$FUZZ_TIME \
        -print_final_stats=1 \
        -detect_leaks=0 \
        -timeout=30 \
        -len_control=0 \
        > "$run_log" 2>&1 || true

    local edge_cov=$(grep "cov:" "$run_log" | tail -1 | grep -oP 'cov: \K[0-9]+')
    [ -z "$edge_cov" ] && edge_cov=0

    local execs=$(grep "stat::number_of_executed_units:" "$run_log" | grep -oP ': \K[0-9]+')
    [ -z "$execs" ] && execs=$(grep "^#[0-9]" "$run_log" | tail -1 | grep -oP '^#\K[0-9]+')
    [ -z "$execs" ] && execs=0

    local func_sig=$(grep "signature" "$output_dir/benchmark.yaml" 2>/dev/null | head -1 | sed 's/.*"signature": "//;s/".*//')
    [ -z "$func_sig" ] && func_sig="$benchmark_id"

    echo -e "${benchmark_id}\t${func_sig}\t${edge_cov}\t${corpus_size}\t${execs}\tok" >> "$TSV_OUTPUT"
    echo "Done: $benchmark_id -> cov: $edge_cov"

    rm -rf "$fuzz_corpus"
}

export -f run_fuzzer
export OSS_FUZZ_DIR PROJECT RUN_DIR TSV_OUTPUT FUZZ_TIME TARGET_NAME

echo "$TARGETS" | xargs -P $MAX_PARALLEL -I{} bash -c 'run_fuzzer "$@"' _ {}

echo ""
echo "=== Phase 3: Results ==="
echo "Results saved to: $TSV_OUTPUT"
echo ""
sort -t$'\t' -k3 -rn "$TSV_OUTPUT" | head -20
echo ""
echo "Total targets: $(grep -c "^${PROJECT}-" "$TSV_OUTPUT")"
echo "With coverage > 0: $(grep "^${PROJECT}-" "$TSV_OUTPUT" | awk -F'\t' '$3 > 0' | wc -l)"
