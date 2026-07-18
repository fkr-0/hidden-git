#!/usr/bin/env python3
"""Extract SLSA provenance statements from a BuildKit OCI archive."""

from __future__ import annotations

import json
import sys
import tarfile
from pathlib import Path
from typing import Any


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: extract-oci-provenance.py <archive> <output>", file=sys.stderr)
        return 2

    archive = Path(sys.argv[1])
    output = Path(sys.argv[2])
    statements: list[dict[str, Any]] = []

    with tarfile.open(archive) as tar:
        def read_json(path: str) -> dict[str, Any]:
            member = tar.extractfile(path)
            if member is None:
                raise RuntimeError(f"missing OCI object: {path}")
            return json.load(member)

        def read_blob(digest: str) -> dict[str, Any]:
            algorithm, value = digest.split(":", 1)
            if algorithm != "sha256":
                raise RuntimeError(f"unsupported OCI digest: {digest}")
            return read_json(f"blobs/sha256/{value}")

        def walk_descriptor(descriptor: dict[str, Any]) -> None:
            obj = read_blob(descriptor["digest"])
            for child in obj.get("manifests", []):
                walk_descriptor(child)

            if descriptor.get("annotations", {}).get(
                "vnd.docker.reference.type"
            ) != "attestation-manifest":
                return

            for layer in obj.get("layers", []):
                annotations = layer.get("annotations", {})
                if layer.get("mediaType") != "application/vnd.in-toto+json":
                    continue
                if annotations.get("in-toto.io/predicate-type") != (
                    "https://slsa.dev/provenance/v1"
                ):
                    continue
                statements.append(read_blob(layer["digest"]))

        index = read_json("index.json")
        for descriptor in index.get("manifests", []):
            walk_descriptor(descriptor)

    if not statements:
        raise RuntimeError("no SLSA v1 provenance statement found")

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        json.dump(statements[0] if len(statements) == 1 else statements, handle,
                  indent=2, sort_keys=True)
        handle.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
