"""Choose a monotonically increasing release version without rewriting main."""

import os
from pathlib import Path
import re
import subprocess


def parse(value):
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", value):
        raise ValueError(f"Invalid release version: {value!r}")
    return tuple(map(int, value.split(".")))


def select(floor, tags, commit):
    minimum = parse(floor)
    versions = {}
    for tag, target in tags.items():
        if re.fullmatch(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", tag):
            versions[parse(tag[1:])] = target
    existing = [version for version, target in versions.items() if target == commit]
    if existing:
        chosen = max(existing)
    elif versions:
        major, minor, patch = max(versions)
        chosen = max(minimum, (major, minor, patch + 1))
    else:
        chosen = minimum
    if versions and chosen < max(versions):
        raise ValueError("This commit has been superseded by a newer release")
    return ".".join(map(str, chosen))


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


if __name__ == "__main__":
    tags = {tag: git("rev-list", "-n", "1", tag) for tag in git("tag", "--list", "v*").splitlines()}
    version = select(Path("VERSION").read_text().strip(), tags, os.environ["GITHUB_SHA"])
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"version={version}\ntag=v{version}\n")
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write(f"VERSION={version}\nTAG=v{version}\n")
    print(f"Release v{version} from {os.environ['GITHUB_SHA']}")
