#!/bin/bash

CORPUS_DIR=${CORPUS_DIR:-"/corpus"}
TIMEOUT=30m
COVERAGE_OUTPUT_DIR=${COVERAGE_OUTPUT_DIR:-$OUT}
LOGS_DIR="$COVERAGE_OUTPUT_DIR/logs"

function run_fuzz_target {
  local target=$1

  local corpus_real="$CORPUS_DIR"

  # -merge=1 requires an output directory, create a new, empty dir for that.
  local corpus_dummy="$OUT/dummy_corpus_dir_for_${target}"
  rm -rf $corpus_dummy && mkdir -p $corpus_dummy

  total_corpus_num=$(find $corpus_real -type f | wc -l)

  echo "total_corpus_num: $total_corpus_num"

  # Use -merge=1 instead of -runs=0 because merge is crash resistant and would
  # let to get coverage using all corpus files even if there are crash inputs.
  # Merge should not introduce any significant overhead compared to -runs=0,
  # because (A) corpuses are already minimized; (B) we do not use sancov, and so
  # libFuzzer always finishes merge with an empty output dir.
  # Use 100s timeout instead of 25s as code coverage builds can be very slow.
  local args="-merge=1 -timeout=100 $corpus_dummy $corpus_real"

  timeout $TIMEOUT $OUT/$target $args &> $LOGS_DIR/$target.log
  if (( $? != 0 )); then
    echo "Error occured while running $target:"
    cat $LOGS_DIR/$target.log
  fi

  corpus_num=$(find $corpus_dummy -type f | wc -l)

  echo "unique_cropus_num:$corpus_num" | tee -a $LOGS_DIR/"${target}_cmin.log"

  rm -rf $corpus_dummy

}

run_fuzz_target $1