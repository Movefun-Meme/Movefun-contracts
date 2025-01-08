import os
import tempfile
import base64
import subprocess

CONTRACT_TEMPLATE = """
module {address}::{module_name} {{
    struct {struct_name} {{}}
}}
"""

MOVE_TOML_TEMPLATE = """
[package]
name = "{package_name}"
version = "0.0.1"

[dependencies]
AptosFramework = {{ git = "https://github.com/aptos-labs/aptos-core.git", subdir = "aptos-move/framework/aptos-framework/", rev = "main" }}

[addresses]
{module_name} = "{address}"
"""

def compile_contract(address, token_name):
    try:
        module_name = token_name
        struct_name = token_name
        package_name = f"{token_name.lower()}_package"

        with tempfile.TemporaryDirectory() as temp_dir:
            sources_dir = os.path.join(temp_dir, "sources")
            os.makedirs(sources_dir, exist_ok=True)

            contract_path = os.path.join(sources_dir, f"{module_name}.move")
            with open(contract_path, 'w') as f:
                f.write(CONTRACT_TEMPLATE.format(address=address, module_name=module_name, struct_name=struct_name))

            toml_path = os.path.join(temp_dir, "Move.toml")
            with open(toml_path, 'w') as f:
                f.write(MOVE_TOML_TEMPLATE.format(package_name=package_name, module_name=module_name, address=address))

            print(f"Temporary directory contents: {os.listdir(temp_dir)}")
            print(f"Sources directory contents: {os.listdir(sources_dir)}")

            try:
                result = subprocess.run(['aptos', 'move', 'compile', '--save-metadata', '--package-dir', temp_dir, '--named-addresses', f"{module_name}={address}"], 
                                        capture_output=True, text=True, check=True)
                print("Compilation output:", result.stdout)
            except subprocess.CalledProcessError as e:
                print("Compilation error output:", e.output)
                raise Exception(f"Compilation failed: {e.output}")
            except Exception as e:
                raise Exception(f"Unexpected error during compilation: {str(e)}")

            build_dir = os.path.join(temp_dir, "build", package_name)
            module_path = os.path.join(build_dir, "bytecode_modules", f"{module_name}.mv")
            metadata_path = os.path.join(build_dir, "package-metadata.bcs")

            print(f"Build directory contents: {os.listdir(build_dir) if os.path.exists(build_dir) else 'Build directory not found'}")
            if os.path.exists(os.path.join(build_dir, "bytecode_modules")):
                print(f"Bytecode modules directory contents: {os.listdir(os.path.join(build_dir, 'bytecode_modules'))}")

            if not os.path.exists(module_path):
                raise Exception(f"Compiled module file not found at {module_path}")
            if not os.path.exists(metadata_path):
                raise Exception(f"Metadata file not found at {metadata_path}")

            with open(module_path, 'rb') as f:
                module_content = base64.b64encode(f.read()).decode('utf-8')
            with open(metadata_path, 'rb') as f:
                metadata_content = base64.b64encode(f.read()).decode('utf-8')

            return {
                'module': module_content,
                'metadata': metadata_content
            }

    except Exception as e:
        raise Exception(f"Unexpected error: {str(e)}")