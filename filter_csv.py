import csv

# Filenames
harness_file = '/tmp/harness.csv'
src_file = '/tmp/src.csv'
output_file = 'filtered_harness.csv'

# Read the names from src.csv
src_names = set()
with open(harness_file, 'r') as src:
    reader = csv.reader(src, delimiter='\t')
    for row in reader:
        src_names.add(row[0])

# Filter harness.csv based on names in src.csv
filtered_rows = []
with open(src_file, 'r') as harness:
    reader = csv.reader(harness, delimiter='\t')
    for row in reader:
        if row[0] in src_names:
            filtered_rows.append(row)

# Write the filtered rows to a new CSV file
with open(output_file, 'w', newline='') as output:
    writer = csv.writer(output)
    writer.writerows(filtered_rows)

print(f"Filtered rows written to {output_file}")
