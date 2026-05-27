#!/usr/bin/env python3
"""
Rebuild generated fuzz drivers from results directories.

This script takes the generated fuzz target source files and rebuilds them
using the oss-fuzz infrastructure, producing ready-to-run fuzzer binaries.

Usage:
  python3 rebuild_fuzz_drivers.py \
    --results-dir ./results-qpdf \
    --oss-fuzz-dir /mnt/ssd/fuzzing/oss-fuzz-repo \
    --output-dir ./rebuilt-qpdf \
    --project qpdf \
    --max-parallel 2

Steps per target:
1. Copy the oss-fuzz project as a new project
2. Replace the fuzz target source with the generated one
3. Build the Docker image
4. Run `compile` to produce the fuzzer binary
5. Copy binary + corpus to output dir
"""

import argparse
import json
import os
import shutil
import subprocess as sp
import sys
from pathlib import Path
from multiprocessing import Pool


def find_successful_targets(results_dir: str) -> list[dict]:
    """Find targets that have a fuzz_target source and non-empty corpus."""
    targets = []
    results_path = Path(results_dir)

    for output_dir in sorted(results_path.glob("output-*")):
        fuzz_targets_dir = output_dir / "fuzz_targets"
        corpora_dir = output_dir / "corpora"

        if not fuzz_targets_dir.exists():
            continue

        fuzz_target_files = list(fuzz_targets_dir.glob("*.fuzz_target"))
        if not fuzz_target_files:
            continue

        # Check for corpus
        corpus_dir = None
        corpus_count = 0
        if corpora_dir.exists():
            for subdir in corpora_dir.iterdir():
                if subdir.is_dir():
                    files = list(subdir.iterdir())
                    if files:
                        corpus_dir = str(subdir)
                        corpus_count = len(files)
                        break

        # Read benchmark yaml for target info
        benchmark_yaml = output_dir / "benchmark.yaml"
        target_name = "qpdf_fuzzer"
        target_path = ""
        if benchmark_yaml.exists():
            import yaml
            with open(benchmark_yaml) as f:
                data = yaml.safe_load(f)
            target_name = data.get('target_name', 'qpdf_fuzzer')
            target_path = data.get('target_path', '')

        targets.append({
            'output_dir': str(output_dir),
            'benchmark_id': output_dir.name.replace('output-', ''),
            'fuzz_target_src': str(fuzz_target_files[0]),
            'corpus_dir': corpus_dir,
            'corpus_count': corpus_count,
            'target_name': target_name,
            'target_path': target_path,
        })

    return targets


def rebuild_target(args_tuple) -> dict:
    """Rebuild a single fuzz target."""
    target, oss_fuzz_dir, output_dir, project = args_tuple

    benchmark_id = target['benchmark_id']
    target_name = target['target_name']
    target_path = target['target_path']
    fuzz_target_src = target['fuzz_target_src']

    # Create generated project name
    parts = benchmark_id.split('-', 1)
    func_id = parts[1].lstrip('_') if len(parts) == 2 else benchmark_id
    generated_project = f"{project}-{func_id[:60]}-rebuild"

    result = {
        'benchmark_id': benchmark_id,
        'generated_project': generated_project,
        'success': False,
        'binary_path': '',
        'error': '',
    }

    try:
        # 1. Copy project
        src_project = os.path.join(oss_fuzz_dir, 'projects', project)
        dst_project = os.path.join(oss_fuzz_dir, 'projects', generated_project)

        if os.path.exists(dst_project):
            shutil.rmtree(dst_project)
        shutil.copytree(src_project, dst_project)

        # 2. Replace fuzz target source
        # The target_path tells us where the source goes in the container
        # e.g., /src/qpdf/fuzz/qpdf_fuzzer.cc
        # We need to inject our source into the Docker build
        # Strategy: append a COPY command to the Dockerfile
        with open(fuzz_target_src) as f:
            generated_source = f.read()

        # Write generated source next to Dockerfile
        target_filename = os.path.basename(target_path) if target_path else f"{target_name}.cc"
        generated_src_path = os.path.join(dst_project, target_filename)
        with open(generated_src_path, 'w') as f:
            f.write(generated_source)

        # Append COPY to Dockerfile to replace the original target
        dockerfile_path = os.path.join(dst_project, 'Dockerfile')
        with open(dockerfile_path, 'a') as f:
            f.write(f'\nCOPY {target_filename} {target_path}\n')

        # 3. Build Docker image
        build_image_cmd = [
            'docker', 'build', '-t', f'gcr.io/oss-fuzz/{generated_project}',
            dst_project
        ]
        img_result = sp.run(build_image_cmd, capture_output=True, text=True,
                            timeout=300, cwd=oss_fuzz_dir)
        if img_result.returncode != 0:
            result['error'] = f"Image build failed: {img_result.stderr[-500:]}"
            return result

        # 4. Compile the fuzzer
        out_dir = os.path.join(oss_fuzz_dir, 'build', 'out', generated_project)
        work_dir = os.path.join(oss_fuzz_dir, 'build', 'work', generated_project)
        os.makedirs(out_dir, exist_ok=True)
        os.makedirs(work_dir, exist_ok=True)

        compile_cmd = [
            'docker', 'run', '--rm', '--privileged',
            '--shm-size=2g', '--platform', 'linux/amd64', '-i',
            '-e', 'FUZZING_ENGINE=libfuzzer',
            '-e', 'SANITIZER=address',
            '-e', 'ARCHITECTURE=x86_64',
            '-e', f'PROJECT_NAME={generated_project}',
            '-e', 'FUZZING_LANGUAGE=c++',
            '-v', f'{out_dir}:/out',
            '-v', f'{work_dir}:/work',
            '--entrypoint', '/bin/bash',
            f'gcr.io/oss-fuzz/{generated_project}',
            '-c', 'rm -rf /out/* /work/* && compile && chmod 777 -R /out/*'
        ]
        compile_result = sp.run(compile_cmd, capture_output=True, text=True,
                                timeout=600, cwd=oss_fuzz_dir)
        if compile_result.returncode != 0:
            result['error'] = f"Compile failed: {compile_result.stderr[-500:]}"
            return result

        # 5. Check binary exists
        binary_path = os.path.join(out_dir, target_name)
        if not os.path.exists(binary_path):
            # Try to find any binary in /out
            for f in os.listdir(out_dir):
                full = os.path.join(out_dir, f)
                if os.path.isfile(full) and os.access(full, os.X_OK):
                    binary_path = full
                    break

        if not os.path.exists(binary_path):
            result['error'] = f"Binary not found in {out_dir}"
            return result

        # 6. Copy to output dir
        target_output = os.path.join(output_dir, benchmark_id)
        os.makedirs(target_output, exist_ok=True)
        shutil.copy2(binary_path, os.path.join(target_output, target_name))

        # Copy corpus if exists
        if target['corpus_dir']:
            corpus_dst = os.path.join(target_output, 'corpus')
            if os.path.exists(corpus_dst):
                shutil.rmtree(corpus_dst)
            shutil.copytree(target['corpus_dir'], corpus_dst)

        # Copy source for reference
        shutil.copy2(fuzz_target_src,
                     os.path.join(target_output, 'fuzz_target.cc'))

        result['success'] = True
        result['binary_path'] = os.path.join(target_output, target_name)

    except sp.TimeoutExpired:
        result['error'] = "Timeout during build"
    except Exception as e:
        result['error'] = str(e)
    finally:
        # Cleanup generated project dir to save space
        dst_project = os.path.join(oss_fuzz_dir, 'projects', generated_project)
        if os.path.exists(dst_project):
            shutil.rmtree(dst_project, ignore_errors=True)

    return result


def main():
    parser = argparse.ArgumentParser(
        description='Rebuild generated fuzz drivers into ready-to-run binaries')
    parser.add_argument('--results-dir', required=True,
                        help='Results directory with generated fuzz targets')
    parser.add_argument('--oss-fuzz-dir', default='/mnt/ssd/fuzzing/oss-fuzz-repo',
                        help='Path to oss-fuzz checkout')
    parser.add_argument('--output-dir', default='./rebuilt-drivers',
                        help='Output directory for rebuilt binaries')
    parser.add_argument('--project', required=True,
                        help='OSS-Fuzz project name (e.g., qpdf)')
    parser.add_argument('--max-parallel', type=int, default=1,
                        help='Max parallel builds')
    parser.add_argument('--only-with-corpus', action='store_true',
                        help='Only rebuild targets that have a corpus')
    parser.add_argument('--limit', type=int, default=0,
                        help='Limit number of targets to rebuild (0=all)')
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    targets = find_successful_targets(args.results_dir)
    if args.only_with_corpus:
        targets = [t for t in targets if t['corpus_count'] > 0]

    if args.limit > 0:
        targets = targets[:args.limit]

    print(f"Found {len(targets)} targets to rebuild")
    print(f"Project: {args.project}")
    print(f"Output: {args.output_dir}")
    print()

    results = []
    for i, target in enumerate(targets):
        print(f"[{i+1}/{len(targets)}] Building {target['benchmark_id'][:60]}...")
        result = rebuild_target((target, args.oss_fuzz_dir, args.output_dir, args.project))
        results.append(result)
        if result['success']:
            print(f"  SUCCESS: {result['binary_path']}")
        else:
            print(f"  FAILED: {result['error'][:100]}")

        # Prune docker to save space
        if (i + 1) % 5 == 0:
            sp.run(['docker', 'container', 'prune', '-f'],
                   capture_output=True)
            sp.run(['docker', 'image', 'prune', '-f'],
                   capture_output=True)

    # Summary
    successful = [r for r in results if r['success']]
    print(f"\n{'='*60}")
    print(f"REBUILD SUMMARY")
    print(f"{'='*60}")
    print(f"Total attempted: {len(results)}")
    print(f"Successful: {len(successful)}")
    print(f"Failed: {len(results) - len(successful)}")

    if successful:
        print(f"\nRebuilt binaries in: {args.output_dir}")
        print(f"\nTo run a fuzzer:")
        print(f"  ./{args.output_dir}/<benchmark_id>/{targets[0]['target_name']} "
              f"./{args.output_dir}/<benchmark_id>/corpus/")

    # Save report
    report_path = os.path.join(args.output_dir, 'rebuild_report.json')
    with open(report_path, 'w') as f:
        json.dump(results, f, indent=2)
    print(f"\nReport saved to: {report_path}")


if __name__ == '__main__':
    main()
