#!/usr/bin/env python3
"""Fail when a YAML file repeats a key in one mapping.

Helm keeps the last copy of a repeated key without a warning, so a pasted
duplicate block silently overrides the edits above it.

Usage: check-duplicate-keys.py FILE...
"""
import sys

import yaml


class StrictLoader(yaml.SafeLoader):
    pass


def construct_mapping(loader, node, deep=False):
    seen = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise yaml.constructor.ConstructorError(
                None, None, f"duplicate key {key!r}", key_node.start_mark)
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_mapping)

failed = False
for path in sys.argv[1:]:
    try:
        with open(path) as f:
            yaml.load(f, Loader=StrictLoader)
    except yaml.YAMLError as err:
        print(f"{path}: {err}")
        failed = True
sys.exit(1 if failed else 0)
