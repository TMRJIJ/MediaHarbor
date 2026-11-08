#!/usr/bin/env python3
"""Build the bundled Python and JavaScript runtimes from pinned releases."""

import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1] / "MediaHarbor" / "GalleryRuntime"
LOCK = Path(__file__).with_name("gallery-runtime.lock.json")
VIDEO_LOCK = Path(__file__).with_name("video-runtime.lock.json")


def fetch(record, destination):
    with urllib.request.urlopen(record["url"], timeout=90) as response:
        shutil.copyfileobj(response, destination)
    destination.seek(0)
    if hashlib.file_digest(destination, "sha256").hexdigest() != record["sha256"]:
        raise ValueError("Checksum mismatch for " + record["url"])
    destination.seek(0)


def main():
    dependencies = json.loads(LOCK.read_text())
    video = json.loads(VIDEO_LOCK.read_text())
    with tempfile.TemporaryDirectory(prefix="mediaharbor-runtime-") as temporary:
        work = Path(temporary)
        for arch, record in dependencies["python"].items():
            with tempfile.TemporaryFile() as download:
                fetch(record, download)
                with tarfile.open(fileobj=download, mode="r:gz") as archive:
                    archive.extractall(work / arch, filter="data")

        assembled = work / "runtime"
        (assembled / "bin").mkdir(parents=True)
        packages = assembled / "lib" / "python3.13" / "site-packages"
        packages.mkdir(parents=True)
        (packages.parent / "lib-dynload").mkdir()
        (packages.parent / "lib-dynload" / ".empty").touch()
        interpreter = assembled / "bin" / "python3"
        subprocess.run(["lipo", "-create", "-output", interpreter, *[
            work / arch / "python" / "bin" / "python3.13" for arch in dependencies["python"]
        ]], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", interpreter], check=True)

        standard_library = work / "arm64" / "python" / "lib" / "python3.13"
        with zipfile.ZipFile(assembled / "lib" / "python313.zip", "w", zipfile.ZIP_DEFLATED) as library:
            for path in sorted(standard_library.rglob("*.py")):
                relative = path.relative_to(standard_library)
                if relative.parts[0] not in {"site-packages", "idlelib", "tkinter", "turtledemo", "ensurepip"}:
                    library.write(path, relative)
            library.write(standard_library / "LICENSE.txt", "LICENSE.txt")
        shutil.copy2(standard_library / "LICENSE.txt", assembled / "CPython-LICENSE.txt")
        for record in dependencies["wheels"] + video["wheels"]:
            with io.BytesIO() as download:
                fetch(record, download)
                with zipfile.ZipFile(download) as wheel:
                    wheel.extractall(packages)

        for script, name in (("bridge.py", "sites.json"), ("video_bridge.py", "video-sites.json")):
            catalog = subprocess.check_output(
                [interpreter, "-I", "-B", "-S", ROOT / script, "catalog"], text=True)
            (assembled / name).write_text(catalog)

        deno = video["deno"]
        slices = []
        for record in deno["binaries"]:
            binary = work / ("deno-" + record["arch"])
            with tempfile.TemporaryFile() as download:
                fetch(record, download)
                with zipfile.ZipFile(download) as archive, archive.open("deno") as executable:
                    with binary.open("wb") as output:
                        shutil.copyfileobj(executable, output)
            slices.append(binary)
        universal = work / "deno"
        subprocess.run(["lipo", "-create", *slices, "-output", universal], check=True)
        universal.chmod(0o755)
        subprocess.run(["codesign", "--force", "--sign", "-", universal], check=True)
        video_root = ROOT.parent / "VideoRuntime"
        license = work / "Deno-LICENSE.md"
        with license.open("w+b") as destination:
            fetch(deno["license"], destination)

        for name in ("bin", "lib", "CPython-LICENSE.txt", "sites.json", "video-sites.json"):
            target = ROOT / name
            if target.is_dir():
                shutil.rmtree(target)
            elif target.exists():
                target.unlink()
            shutil.move(assembled / name, target)
        shutil.move(universal, video_root / "deno")
        shutil.move(license, video_root / license.name)


if __name__ == "__main__":
    main()
