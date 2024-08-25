#!/bin/bash

# Define the input file
proj_input_file="/tmp/input.txt"
TO_GENERATED_FILE="/mydata/data/code/fuzzing/oss-fuzz/to_generated.txt"
to_count_cov_proj_file="/mydata/data/code/fuzzing/oss-fuzz/to_count_cov_proj.txt"
CSV_HARNESS_FILE="/mydata/data/code/fuzzing/oss-fuzz-gen/filtered_harness.csv"
BENCHMARK_OSS_SEEDS_DIR="/mydata/data/code/fuzzing/oss-fuzz-gen"
OSSFUZZ_DIR="/mydata/data/code/fuzzing/oss-fuzz"
BUILTIN_COV_CSV="/tmp/oss-fuzz_builtin_cov.csv"
OSSFUZZ_AI_COV_CSV="/tmp/oss-fuzz_aigen_cov.csv"

function get_proj_src() {
  project=$1
  src_path=$2
  docker run --rm --privileged --shm-size=2g --platform linux/amd64 -e FUZZING_ENGINE=libfuzzer -e SANITIZER=address -e ARCHITECTURE=x86_64 -e HELPER=True -e FUZZING_LANGUAGE=c++ -v "$OSSFUZZ_DIR/build/out/$1":/out -v "$OSSFUZZ_DIR/build/work/$1":/work -t "gcr.io/oss-fuzz/$1" cp -f $src_path /work/
}

function copy_src_from_docker() {
  # Iterate over each line in the file
  while IFS= read -r line; do
    # Split the line into fields using ':' as the delimiter
    IFS=' ' read -r -a fields <<< "$line"

    # Extract project_name and source_code_file
    project_name="${fields[0]}"
    source_code_file_with_info="${fields[1]}"

    # Remove the line number and column number from source_code_file
    source_code_file="${source_code_file_with_info%:*:*}"

    # Check if source_code_file is not empty
    if [[ -n "$source_code_file" ]]; then
      # Process the project_name and source_code_file
      echo "Processing project: $project_name, source file: $source_code_file"
      
      get_proj_src "$project_name" "$source_code_file"
    fi
  done < "$proj_input_file"
}

function batch_gen_seeds() {
  for harness in $(cat $TO_GENERATED_FILE); do
    IFS=',' read -r -a fields <<< "$harness"
    # IFS=$'\t' read -r -a fields <<< "$harness"
    project_name="${fields[0]}"
    src_path="${fields[1]}"
    echo "Generating... Project: $project_name,  Source Path: $src_path"
    # get_proj_src "$project_name" "$src_path"
    python test_one_corpus_generate.py $project_name $src_path
  done
}

function run_batch_seedgen_scripts() {
  for project in $(cat $to_count_cov_proj_file); do
    echo "Running batch seedgen for project: $project"
    pushd "$OSSFUZZ_DIR" && \
      mkdir -p build/work/$project && \
      python infra/helper.py build_image --no-pull $project && \
      # python infra/helper.py build_fuzzers --sanitizer=coverage $project && \
      echo "cp -f $BENCHMARK_OSS_SEEDS_DIR/save_ai_corpus.sh ./build/work/$project/" && \
      cp -f $BENCHMARK_OSS_SEEDS_DIR/save_ai_corpus.sh ./build/work/$project/ && \
      mkdir -p ./build/work/$project/corpus && \
      cp -f $BENCHMARK_OSS_SEEDS_DIR/benchmark-seedgen/$project/*.py ./build/work/$project/ && \
      docker run --rm --privileged --shm-size=2g --platform linux/amd64 -e FUZZING_ENGINE=libfuzzer -e SANITIZER=address -e ARCHITECTURE=x86_64 -e HELPER=True -e FUZZING_LANGUAGE=c++ -v "$OSSFUZZ_DIR/build/out/$project":/out -v "$OSSFUZZ_DIR/build/work/$project":/work -t "gcr.io/oss-fuzz/$project" "/work/save_ai_corpus.sh" && \
      popd
  done
}

function run_cmin_scripts() {
  while IFS= read -r line; do
    # Split the line into fields using ':' as the delimiter
    IFS=',' read -r -a fields <<< "$line"

    # Extract project_name and source_code_file
    project_name="${fields[0]}"
    binary_name="${fields[1]}"
    source_code_file_with_info="${fields[2]}"
    echo "Running cmin for project: $project_name, Binary: $binary_name"
    cp -f $BENCHMARK_OSS_SEEDS_DIR/cmin.sh $OSSFUZZ_DIR/build/out/$project_name/
    pushd "$OSSFUZZ_DIR" && \
      mkdir -p build/work/$project && \
      docker run --rm --privileged --shm-size=4g --platform linux/amd64 -e FUZZING_ENGINE=libfuzzer -e HELPER=True -e PROJECT="$project_name" -e SANITIZER=coverage -e 'COVERAGE_EXTRA_ARGS= ' -e ARCHITECTURE=x86_64 -v $OSSFUZZ_DIR/build/corpus/$project_name/aigen_corpus:/corpus -v $OSSFUZZ_DIR/build/out/$project_name:/out -t gcr.io/oss-fuzz-base/base-runner /out/cmin.sh $binary_name
    popd
  done < "$CSV_HARNESS_FILE"
}

function copy_generated_corpus() {
  # Find all aigen_corpus directories under build/work/
  pushd $OSSFUZZ_DIR
  find build/work/ -iname aigen_corpus | while read -r corpus_path; do
      # Extract the project name from the path
      project=$(basename "$(dirname "$corpus_path")")

      # Create the target directory for the project
      mkdir -p "build/corpus/$project"

      # Copy the aigen_corpus directory to the target directory
      cp -r "$corpus_path" "build/corpus/$project/"
  done
  popd
}

function count_builtin_cov() {
  pushd $OSSFUZZ_DIR
  find build/cov_report/builtin -name summary.json | grep report_target | while read -r summary_path; do
      binary_name=$(basename "$(dirname "$(dirname "$summary_path")")")
      project=$(basename "$(dirname "$(dirname "$(dirname "$(dirname "$summary_path")")")")")
      cov=$(jq .data[].totals.lines.percent < "$summary_path")
      printf "$project\t$binary_name\t$cov\n" | tee -a $BUILTIN_COV_CSV
  done

  popd
}

function generate_cov() {
  # python infra/helper.py coverage --fuzz-target=$binary_name --corpus-dir=$corpus_dir $project --no-serve
  while IFS= read -r line; do
    # Split the line into fields using ':' as the delimiter
    IFS=',' read -r -a fields <<< "$line"

    # Extract project_name and source_code_file
    project_name="${fields[0]}"
    binary_name="${fields[1]}"
    source_code_file_with_info="${fields[2]}"

    # Remove the line number and column number from source_code_file
    source_code_file="${source_code_file_with_info%:*:*}"

    echo "Project Name: $project_name, Binary Name: $binary_name, Source Code File: $source_code_file"

    # if build/cov_report/builtin/$project exists, skip
    if [ -d "$OSSFUZZ_DIR/build/corpus/$project_name/aigen_corpus" ] ; then
      echo "Generating code coverage: $project_name"
      # python infra/helper.py build_fuzzers --sanitizer=coverage $project_name
      timeout 20m python infra/helper.py coverage --fuzz-target=$binary_name --corpus-dir="$OSSFUZZ_DIR/build/corpus/$project_name/aigen_corpus" --no-serve $project_name 
      if [ $? -eq 124 ]; then
        echo "Timeout reached. Running another command..."
        docker stop $(docker ps -q)
      fi
      mkdir -p $OSSFUZZ_DIR/build/cov_report/aigen/$project_name
      cp -rf $OSSFUZZ_DIR/build/out/$project_name/report_target $OSSFUZZ_DIR/build/cov_report/aigen/$project_name/
    fi

  done < "$CSV_HARNESS_FILE"
}

function generate_cov_builtin_seeds() {
  # python infra/helper.py coverage --fuzz-target=$binary_name --corpus-dir=$corpus_dir $project --no-serve
  while IFS= read -r line; do
    # Split the line into fields using ':' as the delimiter
    IFS=',' read -r -a fields <<< "$line"

    # Extract project_name and source_code_file
    project_name="${fields[0]}"
    binary_name="${fields[1]}"
    source_code_file_with_info="${fields[2]}"

    # Remove the line number and column number from source_code_file
    source_code_file="${source_code_file_with_info%:*:*}"

    echo "Project Name: $project_name, Binary Name: $binary_name, Source Code File: $source_code_file"

    # if build/cov_report/builtin/$project exists, skip
    if [ -d "$OSSFUZZ_DIR/build/corpus/$project_name/builtin_corpus" ] ; then
      echo "Generating code coverage: $project_name"
      if ! [ -d "$OSSFUZZ_DIR/build/out/$project_name/src" ] ; then
        python infra/helper.py build_fuzzers --sanitizer=coverage $project_name
      fi  
      timeout 30m python infra/helper.py coverage --fuzz-target=$binary_name --corpus-dir="$OSSFUZZ_DIR/build/corpus/$project_name/builtin_corpus" --no-serve $project_name 
      if [ $? -eq 124 ]; then
        echo "Timeout reached. Running another command..."
        docker stop $(docker ps -q)
      fi
      mkdir -p $OSSFUZZ_DIR/build/cov_report/builtin/$project_name
      cp -rf $OSSFUZZ_DIR/build/out/$project_name/report_target $OSSFUZZ_DIR/build/cov_report/builtin/$project_name/
    fi

  done < "$CSV_HARNESS_FILE"
}

function filter_builtin_cov() {
  pushd $OSSFUZZ_DIR
  while IFS= read -r line; do
    # Split the line into fields using ':' as the delimiter
    IFS=',' read -r -a fields <<< "$line"

    # Extract project_name and source_code_file
    project_name="${fields[0]}"
    binary_name="${fields[1]}"
    source_code_file_with_info="${fields[2]}"
    language=$(cat $OSSFUZZ_DIR/projects/$project_name/project.yaml | yq ".language")

    cov_per_text=$(grep $binary_name $BUILTIN_COV_CSV | grep $project_name)
    if [ $? -ne 0 ]; then
      cov_per="NA"
    else
      cov_per=$(echo $cov_per_text | head -n1 | awk '{print $3}')
    fi

    # echo $cov_per
    printf "$project_name,$language,$binary_name,${source_code_file_with_info}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tee -a /tmp/filtered_harness.csv
    echo ",$cov_per" | tee -a /tmp/filtered_harness.csv

  done < "$CSV_HARNESS_FILE"

  popd
}

function filter_ossfuzz_aigen_cov() {
  # TODO: Implement this function
  pushd $OSSFUZZ_DIR
  while IFS= read -r line; do
    # Split the line into fields using ':' as the delimiter
    IFS=',' read -r -a fields <<< "$line"

    # Extract project_name and source_code_file
    project_name="${fields[0]}"
    binary_name="${fields[1]}"
    source_code_file_with_info="${fields[2]}"

    cov_per_text=$(grep $binary_name $OSSFUZZ_AI_COV_CSV | grep $project_name)
    if [ $? -ne 0 ]; then
      cov_per="NA"
    else
      cov_per=$(echo $cov_per_text | head -n1 | awk '{print $3}')
    fi

    # echo $cov_per
    printf "$project_name,$binary_name,${source_code_file_with_info}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tee -a /tmp/filtered_harness.csv
    echo ,$cov_per | tee -a /tmp/filtered_harness.csv

  done < "$CSV_HARNESS_FILE"

  popd
}

# copy_src_from_docker
# batch_gen_seeds

# run_batch_seedgen_scripts

generate_cov

# filter_builtin_cov

# filter_ossfuzz_aigen_cov

# generate_cov_builtin_seeds