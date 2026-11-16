"""Install the verified CUDA training environment without changing global Python."""
from pathlib import Path
import subprocess
import sys
import venv


def main():
    here = Path(__file__).resolve().parent
    env_dir = here / ".venv"
    py = env_dir / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")
    if not py.exists():
        venv.EnvBuilder(with_pip=True).create(env_dir)
    for requirements in ("requirements-cuda.txt", "requirements.txt"):
        subprocess.run([str(py), "-m", "pip", "install", "--disable-pip-version-check",
                        "-r", str(here / requirements)], cwd=here, check=True)
    subprocess.run([str(py), "-c", "from tankrl.runtime import hardware_info, resolve_device; "
                    "print(hardware_info()); print('Verified:', resolve_device('cuda'))"],
                   cwd=here, check=True)
    print("GPU setup complete. Open dashboard.bat and choose Hybrid (CPU inference + CUDA updates).")


if __name__ == "__main__":
    main()
