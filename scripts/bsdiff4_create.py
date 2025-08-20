# scripts/bsdiff4_create.py
import bsdiff4
import sys
import os

def create_patch(old_file_path, new_file_path, patch_file_path):
    """
    Creates a bsdiff4 patch from old_file to new_file.
    """
    try:
        print(f"Reading old file: {old_file_path}")
        with open(old_file_path, 'rb') as f_old:
            old_data = f_old.read()

        print(f"Reading new file: {new_file_path}")
        with open(new_file_path, 'rb') as f_new:
            new_data = f_new.read()

        print("Generating patch...")
        patch_data = bsdiff4.diff(old_data, new_data)

        patch_dir = os.path.dirname(patch_file_path)
        if patch_dir:
            os.makedirs(patch_dir, exist_ok=True)

        print(f"Writing patch to: {patch_file_path}")
        with open(patch_file_path, 'wb') as f_patch:
            f_patch.write(patch_data)
        
        print(f"Patch created successfully: {patch_file_path}")

    except FileNotFoundError as e:
        print(f"Error: File not found - {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"An unexpected error occurred: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python bsdiff4_create.py <old_file> <new_file> <patch_file>", file=sys.stderr)
        sys.exit(1)
    
    create_patch(sys.argv[1], sys.argv[2], sys.argv[3])
