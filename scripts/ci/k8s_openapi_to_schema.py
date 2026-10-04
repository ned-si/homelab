#!/usr/bin/env python3
"""Build a standalone, strict JSON schema for one Kubernetes core type.

Usage: k8s_openapi_to_schema.py <openapi-v3.json> <definition> <out.json> [--opaque <definition>...]

yannh/kubernetes-json-schema has no CustomResourceDefinition schema: its
JSONSchemaProps type is recursive, so a standalone (fully inlined) schema cannot
be produced. This converter inlines every `$ref` from the Kubernetes OpenAPI v3
document and replaces each `--opaque` definition (JSONSchemaProps) by `{}`, so
the CRD envelope (names, scope, versions, conversion, metadata) is validated
strictly and only the embedded openAPIV3Schema is left to the API server.
Strictness matches kubeconform's -strict schemas: `additionalProperties: false`
on every object with `properties`; `int-or-string` becomes string|integer.
Stdlib only.
"""
from __future__ import annotations

import json
import sys


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 64
    spec_path, root_name, out_path = argv[:3]
    opaque = set(argv[argv.index("--opaque") + 1:]) if "--opaque" in argv else set()
    schemas = json.load(open(spec_path))["components"]["schemas"]

    def resolve(node, stack):
        if isinstance(node, list):
            return [resolve(x, stack) for x in node]
        if not isinstance(node, dict):
            return node
        if "$ref" in node:
            name = node["$ref"].rsplit("/", 1)[-1]
            if name in opaque:
                return {}
            if name in stack:
                raise SystemExit(f"recursive type {name}; add it to --opaque")
            return resolve(schemas[name], stack | {name})
        if "allOf" in node and len(node["allOf"]) == 1:
            merged = {k: v for k, v in node.items() if k != "allOf"}
            inner = resolve(node["allOf"][0], stack)
            merged.update({k: v for k, v in inner.items() if k not in merged})
            node = merged
        out = {}
        for k, v in node.items():
            if k == "format" and v == "int-or-string":
                continue
            out[k] = resolve(v, stack)
        if node.get("format") == "int-or-string":
            out.pop("type", None)
            out["oneOf"] = [{"type": "string"}, {"type": "integer"}]
        if "properties" in out:
            if "additionalProperties" not in out:
                out["additionalProperties"] = False
            # Like the yannh standalone schemas: an optional field may be null
            # (kustomize and helm emit `creationTimestamp: null`, `status: {...: null}`).
            required = set(out.get("required") or [])
            out["properties"] = {k: (v if k in required else nullable(v)) for k, v in out["properties"].items()}
        return out

    def nullable(s):
        if not isinstance(s, dict) or not s:
            return s
        s = dict(s)
        if isinstance(s.get("type"), str):
            s["type"] = [s["type"], "null"]
        elif "oneOf" in s:
            s["oneOf"] = list(s["oneOf"]) + [{"type": "null"}]
        return s

    schema = resolve(schemas[root_name], {root_name})
    with open(out_path, "w") as fh:
        json.dump(schema, fh, indent=2, sort_keys=True)
        fh.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
