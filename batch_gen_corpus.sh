# Define the input file
proj_input_file="/tmp/input.txt"
to_generated_file="/mydata/data/code/fuzzing/oss-fuzz/to_generated.txt"
to_count_cov_proj_file="/mydata/data/code/fuzzing/oss-fuzz/to_count_cov_proj.txt"
BENCHMARK_OSS_SEEDS_DIR="/mydata/data/code/fuzzing/oss-fuzz-gen"
OSSFUZZ_DIR="/mydata/data/code/fuzzing/oss-fuzz"

function get_proj_src() {
  project=$1
  src_path=$2
  docker run --rm --privileged --shm-size=2g --platform linux/amd64 -e FUZZING_ENGINE=libfuzzer -e SANITIZER=address -e ARCHITECTURE=x86_64 -e HELPER=True -e FUZZING_LANGUAGE=c++ -v "/mydata/data/code/fuzzing/oss-fuzz/build/out/$1":/out -v "/mydata/data/code/fuzzing/oss-fuzz/build/work/$1":/work -t "gcr.io/oss-fuzz/$1" cp -f $src_path /work/
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
  for harness in $(cat $to_generated_file); do
    IFS=',' read -r -a fields <<< "$harness"
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
      mkdir -p build/work/$project
      echo "cp -f $BENCHMARK_OSS_SEEDS_DIR/save_ai_corpus.sh ./build/work/$project/"
      cp -f $BENCHMARK_OSS_SEEDS_DIR/save_ai_corpus.sh ./build/work/$project/ && \
      mkdir -p ./build/work/$project/corpus && \
      cp -f $BENCHMARK_OSS_SEEDS_DIR/benchmark-seedgen/$project/*.py ./build/work/$project/corpus && \
      docker run --rm --privileged --shm-size=2g --platform linux/amd64 -e FUZZING_ENGINE=libfuzzer -e SANITIZER=address -e ARCHITECTURE=x86_64 -e HELPER=True -e FUZZING_LANGUAGE=c++ -v "/mydata/data/code/fuzzing/oss-fuzz/build/out/$project":/out -v "/mydata/data/code/fuzzing/oss-fuzz/build/work/$project":/work -t "gcr.io/oss-fuzz/$project" "/work/save_ai_corpus.sh" && \
      popd
  done
}

# copy_src_from_docker
# batch_gen_seeds

run_batch_seedgen_scripts