#!/bin/bash

OSSFUZZ_DIR="/mydata/data/code/fuzzing/oss-fuzz/"
OSSFUZZGEN_BENCHMARK_DIR="/mydata/data/code/fuzzing/oss-fuzz-gen/benchmark-seedgen-claude3-opus/"
SCRIPT_TIMEOUT=30s
CORPUS_SAVE_NAME="claude3-opus-aigen_corpus"

cd $OSSFUZZ_DIR/build/corpus/

for proj_path in $(ls $OSSFUZZGEN_BENCHMARK_DIR); do
  proj_name=$(basename $proj_path)
  echo "Processing project: $proj_name"
  mkdir -p $proj_name/$CORPUS_SAVE_NAME
  for pyfile in $(ls $OSSFUZZGEN_BENCHMARK_DIR/$proj_path/*.py); do
    echo "Processing script: $pyfile"
    script_name=$(basename $pyfile)
    script_out_dir="${script_name}_out"
    mkdir -p $proj_name/$CORPUS_SAVE_NAME/$script_out_dir
    pushd $proj_name/$CORPUS_SAVE_NAME/$script_out_dir
    timeout $SCRIPT_TIMEOUT python3 $pyfile
    # delete larger files
    find . -type f -size +2M -delete
    popd
  done

done

cd $OSSFUZZ_DIR
# End of script
