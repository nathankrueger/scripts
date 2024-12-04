import glob
import os
import tqdm
import argparse

MAX_SIZE_DOT_UNDERCORE_SIZE=1e4
MAX_DS_STORE_SIZE=1e5

remove_cnt = 0

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Delete pesky files from Mac OS: *._ and .DS_Store")
    parser.add_argument('-d', '--directory', type=str, required=True, description="The directory to search through")
    parser.add_argument('-x', '--execute', type=bool, action='store_true', default=False, description="If set, this won't be a dry run and the files will be unlinked permanently.")
    args = parser.parse_args()

    assert os.path.exists(args.directory)

    # weird ._* Mac files
    files = glob.glob(pathname="**/._*", root_dir=args.directory, recursive=True)
    for file in tqdm.tqdm(files):
        filepath = os.path.join(args.directory, file)
        if os.stat(filepath).st_size > MAX_SIZE_DOT_UNDERCORE_SIZE:
            print(f"Warning large file detected, skipping deletion: {file}")
        else:
            remove_cnt += 1
            if args.execute:
                os.unlink(filepath)
            else:
                print(f"File to remove: {filepath}")

    # .DS_Store files
    files = glob.glob(pathname="**/.DS_Store", root_dir=args.directory, recursive=True)
    for file in tqdm.tqdm(files):
        filepath = os.path.join(args.directory, file)
        if os.stat(filepath).st_size > MAX_DS_STORE_SIZE:
            print(f"Warning large file detected, skipping deletion: {file}")
        else:
            remove_cnt += 1
            if args.execute:
                os.unlink(filepath)
            else:
                print(f"File to remove: {filepath}")

    print(f"Removed: {remove_cnt} junk files")