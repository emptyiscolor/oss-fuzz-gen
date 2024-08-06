#!/bin/bash

cd /work/

# Define the source and destination directories
source_dir="corpus"
destination_dir="aigen_corpus"

# Create the destination directory if it doesn't exist
mkdir -p "$source_dir"
mkdir -p "$destination_dir"

cd $source_dir

# Iterate over all regular files in the source directory
for script_name in ../*.py; do
  # run scripts
  python3 $script_name
  # Extract the filename from the file path
  base_script_name=$(basename "$script_name")
  find . -type f | while IFS= read -r file; do
    # Extract the filename from the file path
    filename=$(basename "$file")

    # Create the new filename with the added prefix
    new_filename="${base_script_name}_${filename}"

    # Copy the file to the destination directory with the new name
    # echo cp -f "$file" "../$destination_dir/$new_filename"
    echo "copying $file to ../$destination_dir/$new_filename"
    cp -f "$file" "../$destination_dir/$new_filename"
    done
done
