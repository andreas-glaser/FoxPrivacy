#!/usr/bin/env python3
"""Validate a generated policies.json against Firefox's own policies-schema.json.

Checking that a top-level policy name exists is not enough: a mistyped
sub-property such as GenerativeAI.Chatbots is accepted by that check, ignored by
Firefox, and shows up only as a line in about:policies that nobody reads.

Deliberately dependency free. The subset of JSON Schema Firefox uses is small:
type, enum, properties and patternProperties.

Usage: validate-schema.py <schema.json> <policies.json>
Prints one problem per line and exits non-zero if there were any.
"""

import json
import sys

TYPES = {
    "string": str, "boolean": bool, "number": (int, float),
    "integer": int, "object": dict, "array": list,
}


def type_ok(value, spec):
    names = spec.get("type")
    if names is None:
        return True
    if isinstance(names, str):
        names = [names]
    for name in names:
        # Firefox uses a "JSON" pseudo-type for values it parses itself.
        if name == "JSON":
            return True
        expected = TYPES.get(name)
        if expected is None:
            return True
        # bool is a subclass of int in Python; keep them distinct.
        if expected in ((int, float), int) and isinstance(value, bool):
            continue
        if isinstance(value, expected):
            return True
    return False


def check(value, spec, path, problems):
    if not type_ok(value, spec):
        problems.append(f"{path}: expected type {spec.get('type')}, got {type(value).__name__}")
        return

    if "enum" in spec and value not in spec["enum"]:
        problems.append(f"{path}: {value!r} is not one of {spec['enum']}")
        return

    if isinstance(value, dict):
        props = spec.get("properties")
        patterns = spec.get("patternProperties")
        for key, sub in value.items():
            if props is not None and key in props:
                check(sub, props[key], f"{path}.{key}", problems)
            elif patterns:
                # Preferences and similar: keys are free-form, values are not.
                for sub_spec in patterns.values():
                    check(sub, sub_spec, f"{path}.{key}", problems)
                    break
            elif props is not None:
                problems.append(
                    f"{path}.{key}: not a property of {path}. "
                    f"Firefox ignores it silently. Known: {', '.join(sorted(props))}"
                )

    if isinstance(value, list) and "items" in spec:
        for i, item in enumerate(value):
            check(item, spec["items"], f"{path}[{i}]", problems)


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2

    schema = json.load(open(sys.argv[1]))["properties"]
    document = json.load(open(sys.argv[2]))

    problems = []
    if "policies" not in document:
        problems.append("the document has no top-level policies object")
    for name, value in document.get("policies", {}).items():
        if name not in schema:
            problems.append(f"{name}: not a policy Firefox knows about")
            continue
        check(value, schema[name], name, problems)

    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
