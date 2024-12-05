import glob
import os
import tqdm
import argparse
import stat

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="List any files smaller than, or larger than a given size")
    parser.add_argument('-d', '--directory', type=str, required=True, help="The directory to search through")
    parser.add_argument('-s', '--small_size_limit', type=int, required=False, help="Find all files smaller than the limit specified")
    parser.add_argument('-l', '--large_size_limit', type=int, required=False, help="Find all files larger than the limit specified")
    args = parser.parse_args()

    assert os.path.exists(args.directory)

    if not (args.small_size_limit is not None) ^ (args.large_size_limit is not None):
        parser.error("Only small_size_limit or large_size_limit must be specified")

    files_found = 0
    files = glob.glob(pathname="**/*", root_dir=args.directory, recursive=True)
    for file in tqdm.tqdm(files):
        filepath = os.path.join(args.directory, file)
        stat_struct = os.stat(filepath)

        if args.small_size_limit:
            if not stat.S_ISDIR(stat_struct.st_mode) and stat_struct.st_size <= args.small_size_limit:
                print(f"Found a small file: {filepath}")
                files_found += 1
        elif args.large_size_limit:
            if not stat.S_ISDIR(stat_struct.st_mode) and stat_struct.st_size >= args.large_size_limit:
                print(f"Found a large file: {filepath}")
                files_found += 1

    print(f"Found {files_found} {'small' if args.small_size_limit else 'large'} files")