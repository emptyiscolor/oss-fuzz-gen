import dataclasses
import json
import logging
import os
import re
import shutil
import time
import argparse
from typing import Optional
from llm_toolkit import corpus_generator
from experiment.benchmark import Benchmark


OSS_FUZZ_DIR = os.getenv("OSS_FUZZ_DIR", "/tmp/")
BENCHMARK_DIR = os.path.join(os.getcwd(), "benchmark-seedgen")

TESTING_SAMPLE_1 = """
void
dns_message_createpools(isc_mem_t *mctx, isc_mempool_t **namepoolp,
			isc_mempool_t **rdspoolp) {
	REQUIRE(mctx != NULL);
	REQUIRE(namepoolp != NULL && *namepoolp == NULL);
	REQUIRE(rdspoolp != NULL && *rdspoolp == NULL);

	isc_mempool_create(mctx, sizeof(dns_fixedname_t), namepoolp);
	isc_mempool_setfillcount(*namepoolp, NAME_FILLCOUNT);
	isc_mempool_setfreemax(*namepoolp, NAME_FREEMAX);
	isc_mempool_setname(*namepoolp, "dns_fixedname_pool");

	isc_mempool_create(mctx, sizeof(dns_rdataset_t), rdspoolp);
	isc_mempool_setfillcount(*rdspoolp, RDATASET_FILLCOUNT);
	isc_mempool_setfreemax(*rdspoolp, RDATASET_FREEMAX);
	isc_mempool_setname(*rdspoolp, "dns_rdataset_pool");
}
"""

# fixer_model_name: "gpt-4o"
# benchmark = Benchmark(
#     project=project_name,
#     language='C',
#     target_path=target_harness_path,
#     target_name=os.path.basename(target_harness_path),
#     function_signature='int main()',
#     function_name='main',
#     return_type='int',
#     params=[],
#     exceptions=[],
#     is_jvm_static=False,
# )


def timeit(func):
    def wrapper(*args, **kwargs):
        start = time.time()
        result = func(*args, **kwargs)
        end = time.time()
        print(f"{func.__name__} took {end - start} seconds")
        return result
    return wrapper


def extend_build_with_seed_gen(ai_binary, benchmark: Benchmark, target_path: str,
                               oss_fuzz_project_name: str):
    """Extends an OSS-Fuzz project with corpus generated programmatically."""
    oss_fuzz_project_path = os.path.join(OSS_FUZZ_DIR,
                                         'projects',
                                         oss_fuzz_project_name)
    generated_corp = corpus_generator.get_script(
        ai_binary, "gpt-4o",
        benchmark)

    corpus_generator_path = os.path.join(oss_fuzz_project_path, 'corp_gen.py')
    with open(corpus_generator_path, 'w') as f:
        f.write(generated_corp)

    with open(os.path.join(oss_fuzz_project_path, 'Dockerfile'), 'a') as f:
        f.write('COPY corp_gen.py $SRC/corp_gen.py\n')
    target_harness_file = os.path.basename(target_path)
    target_harness_file = os.path.splitext(target_harness_file)[0]
    corpus_dst = '/src/generated-corpus/*'
    with open(os.path.join(oss_fuzz_project_path, 'build.sh'), 'a') as f:
        f.write('\n# Generate a corpus for the modified harness.')
        f.write('\nmkdir -p /src/generated-corpus')
        f.write('\npushd /src/generated-corpus')
        f.write('\npython3 $SRC/corp_gen.py')
        f.write('\npopd')
        f.write(
            f'\nzip $OUT/{target_harness_file}_seed_corpus.zip {corpus_dst}')


def call_single_seed_gen(ai_binary: str, model_name, target_harness_path, project_name, target_func_src):
    generated_script = corpus_generator.get_single_script(
        ai_binary, model_name, target_harness_path, project_name, target_func_src)
    print("Generated.")
    return generated_script


def log_to_file(log_file: str, message: str):
    with open(log_file, "a") as f:
        f.write(message + "\n")


def save_single_script(project_name, harness_name, generated_script):
    script_folder = os.path.join(BENCHMARK_DIR, project_name)
    script_path = os.path.join(
        BENCHMARK_DIR, project_name, "gen____" + harness_name + ".py")
    if not os.path.exists(script_folder):
        os.makedirs(script_folder)

    with open(script_path, "w") as f:
        f.write(generated_script)
    print("Saved to ", script_path)


def test_one():
    ai_binary = ""
    model_name = "gpt-4o"
    target_harness_path = "benchmark-seedgen/bind9/dns_message_checksig.c"
    project_name = "bind9"
    target_func_src = TESTING_SAMPLE_1
    print("Start generating base on ", target_harness_path)
    call_single_seed_gen(ai_binary, model_name,
                         target_harness_path, project_name, target_func_src)


def main():
    """
    argv[1]: target_harness_path
    argv[2]: project_name
    """
    parser = argparse.ArgumentParser()
    parser.add_argument("project_name", type=str)
    parser.add_argument("target_harness_path", type=str)
    args = parser.parse_args()
    ai_binary = ""
    model_name = "gpt-4o"
    log_file = "/tmp/metrics_gen_ai_generator.log"
    project_name = args.project_name
    target_harness_path = args.target_harness_path
    harness_filename = os.path.basename(target_harness_path)
    target_func_src = ""
    print("Start generating base on ", target_harness_path)
    start = time.time()
    generated_script = call_single_seed_gen(ai_binary, model_name,
                                            target_harness_path, project_name, target_func_src)
    end = time.time()
    time_consume = end - start
    save_single_script(project_name, harness_filename, generated_script)
    log_text = f"{project_name},{harness_filename},{time_consume}"
    log_to_file(log_file, log_text)


if __name__ == "__main__":
    main()
