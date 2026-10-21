#!/usr/bin/env python3
"""Encode/audit our own FxPlug custom value in observed Motion XML structure.

No host is started. A successful audit verifies structure and archive contents;
it does not establish Motion/FCP custom-view loading or native interaction.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
from pathlib import Path
import plistlib
import re
import string
import struct
import sys
import xml.etree.ElementTree as ET

ALPHABET = "*-0123456789" + string.ascii_uppercase + string.ascii_lowercase
STANDARD = string.ascii_uppercase + string.ascii_lowercase + string.digits + "+/"
PLUGIN_UUID = "FB14B0E6-59B2-4836-916F-CD0C559E9241"
PLACEHOLDER_SHA256 = "a7f8e3a2a431dbb3ce9e777040bb55e701cfe9ab9632e8cbb10359732bc8692e"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def resolve(objects: list, value, seen: frozenset[int] = frozenset()):
    """Read Foundation collection values without instantiating archived classes."""
    if isinstance(value, plistlib.UID):
        index = value.data
        require(0 <= index < len(objects) and index not in seen, "Invalid/cyclic archive UID")
        return resolve(objects, objects[index], seen | {index})
    if isinstance(value, list):
        return [resolve(objects, item, seen) for item in value]
    if isinstance(value, dict):
        if "NS.keys" in value:
            keys, items = value["NS.keys"], value["NS.objects"]
            require(len(keys) == len(items), "Mismatched dictionary keys/objects")
            return {resolve(objects, k, seen): resolve(objects, v, seen) for k, v in zip(keys, items)}
        if "NS.objects" in value:
            return resolve(objects, value["NS.objects"], seen)
        return {k: resolve(objects, v, seen) for k, v in value.items() if k != "$class"}
    return value


def inspect_inner(inner: bytes) -> dict:
    archive = plistlib.loads(inner)
    require(archive.get("$archiver") == "NSKeyedArchiver", "Inner value is not a keyed archive")
    require(set(archive.get("$top", {})) == {"Custom Data"}, "Inner archive requires the Custom Data key")
    objects = archive["$objects"]
    state = objects[archive["$top"]["Custom Data"].data]
    require(objects[state["$class"].data]["$classname"] == "PGInspectorState", "Unexpected custom class")
    classes = sorted({x["$classname"] for x in objects if isinstance(x, dict) and "$classname" in x})
    require(set(classes) <= {"PGInspectorState", "NSObject", "NSDictionary", "NSMutableDictionary", "NSSet", "NSMutableSet", "NSNumber"}, "Unexpected archived class")
    decoded = resolve(objects, state)
    require(decoded.get("schema") == 1 and isinstance(decoded.get("edited"), bool), "Unexpected state schema")
    values = decoded.get("values")
    require(isinstance(values, dict) and values, "Missing numeric control values")
    require(all(isinstance(k, int) and not isinstance(k, bool) and isinstance(v, (int, float)) and math.isfinite(v) for k, v in values.items()), "Non-numeric control values")
    disabled = decoded.get("disabled")
    require(isinstance(disabled, list) and all(isinstance(v, int) for v in disabled), "Invalid disabled controls")
    return {"class": "PGInspectorState", "schema": decoded["schema"], "hasEdits": decoded["edited"],
            "values": values, "disabled": disabled, "classes": classes,
            "innerBytes": len(inner), "innerSHA256": digest(inner)}


def wrap_inner(inner: bytes) -> bytes:
    inspect_inner(inner)
    # This is the observed NSKeyedArchiver wrapper, containing NSData and
    # NSNumber(false), rather than a vendor custom object or copied blob.
    return plistlib.dumps({"$version": 100000, "$archiver": "NSKeyedArchiver",
                           "$top": {"DataIsLegacy": plistlib.UID(2), "BlindDataObject": plistlib.UID(1)},
                           "$objects": ["$null", inner, False]}, fmt=plistlib.FMT_BINARY, sort_keys=False)


def encode_outer(outer: bytes) -> str:
    data = struct.pack(">Q", len(outer)) + b"*" + outer
    data += b"\0" * (-len(data) % 3)
    return base64.b64encode(data).decode("ascii").translate(str.maketrans(STANDARD, ALPHABET))


def decode_text(text: str) -> tuple[bytes, bytes, dict]:
    require(text and len(text) % 4 == 0 and set(text) <= set(ALPHABET), "Invalid Motion text encoding")
    data = base64.b64decode(text.translate(str.maketrans(ALPHABET, STANDARD)), validate=True)
    require(len(data) >= 9 and data[8] == 0x2A, "Unexpected Motion envelope")
    length = int.from_bytes(data[:8], "big")
    require(0 < length <= 16 * 1024 * 1024 and 0 <= len(data) - 9 - length <= 2, "Invalid payload length")
    require(not any(data[9+length:]), "Nonzero envelope padding")
    outer = data[9:9+length]
    archive = plistlib.loads(outer)
    require(archive.get("$archiver") == "NSKeyedArchiver", "Unexpected outer archive")
    require(set(archive.get("$top", {})) == {"DataIsLegacy", "BlindDataObject"}, "Unexpected outer keys")
    objects = archive["$objects"]
    legacy = resolve(objects, archive["$top"]["DataIsLegacy"])
    inner = resolve(objects, archive["$top"]["BlindDataObject"])
    require(legacy is False and isinstance(inner, bytes), "Expected a nonlegacy NSData custom value")
    require(encode_outer(outer) == text, "Text roundtrip mismatch")
    state = inspect_inner(inner)
    state.update({"outerBytes": len(outer), "outerSHA256": digest(outer), "encodedCharacters": len(text), "exactTextRoundtrip": True})
    return outer, inner, state


def find_plugin(root: ET.Element) -> ET.Element:
    matches = [x for x in root.iter("filter") if x.get("pluginUUID") == PLUGIN_UUID]
    require(len(matches) == 1, "Expected exactly one product filter")
    return matches[0]


def parameter(node: ET.Element, channel: str) -> ET.Element:
    require(channel.startswith("./"), "Expected a relative parameter path")
    for identifier in channel[2:].split("/"):
        node = node.find(f"parameter[@id='{identifier}']")
        require(node is not None, f"Unresolved parameter path {channel}")
    return node


def audit(path: Path, parameters_path: Path | None = None) -> tuple[dict, bytes, bytes]:
    root = ET.parse(path).getroot()
    plugin = find_plugin(root)
    custom = parameter(plugin, "./210")
    require(custom.get("name") == "" and custom.get("flags") == "12901679104", "Custom entry differs from observed native structure")
    require(custom.findtext("numberOfKeypoints") == "1" and custom.findtext("keypoint/time") == "0 0 0 0" and custom.find("keypoint/value") is not None, "Missing native custom keypoint skeleton")
    text = custom.findtext("dataValue")
    require(text == custom.findtext("defaultVal"), "Initial current/default custom values differ")
    outer, inner, state = decode_text(text)
    require(state["hasEdits"] is False, "Initial custom value must preserve legacy native settings")
    entities = [x for x in root.iter() if x.tag in {"scenenode", "layer", "group", "filter", "clip", "footage"}]
    ids = [x.get("id") for x in entities]
    require(None not in ids and len(ids) == len(set(ids)), "Duplicate/missing entity identity")
    by_id = dict(zip(ids, entities))
    targets = root.findall("./scene/publishSettings/target")
    require(len(targets) == 3, "Expected exactly three publications")
    require([x.get("name") for x in targets] == ["FCP 版本作者→", "更多模板浏览器访问→", ""], "Unexpected publication order/names")
    require(targets[2].get("object") == plugin.get("id") and targets[2].get("channel") == "./210", "Custom publication does not target this filter")
    for item in targets:
        require(item.get("object") in by_id, "Unresolved publication object")
        parameter(by_id[item.get("object")], item.get("channel"))
    for target, title in zip(targets[:2], ["大鱼先森Media", "dayu.media"]):
        entry = parameter(by_id[target.get("object")], "./2/100")
        require(len(entry.findall("entry")) == 1 and title in ET.tostring(entry, encoding="unicode"), "Copyright menu differs")
    require(parameter(plugin, "./100/12").get("value") == "0.5", "Template midtone default was lost")
    require(parameter(plugin, "./10005").get("value") == "0", "New template OSC must be off")
    for group in range(100, 106):
        parameter(plugin, f"./{group}")
    for identifier in (45, 46, 50, 51, 52, 53):
        parameter(plugin, f"./104/{identifier}")
    for identifier in (60, 61, 62):
        parameter(plugin, f"./{identifier}")
    metadata = parameters_path or path.with_name("PARAMETERS.json")
    listed = json.loads(metadata.read_text())
    for item in listed["parameters"]:
        parameter(plugin, item["channel"])
        require(bool(item["published"]) == (item["id"] == 210), "Legacy flat entry is still published")
    clips = root.findall(".//footage/clip")
    require(len(clips) == 1 and clips[0].findtext("pathURL") == "Drop Zone.tiff", "Unexpected effect source media")
    require(clips[0].get("id") == "510000006" and by_id["510000007"].find("clip") is clips[0], "Broken source clip/footage hierarchy")
    source = by_id["510000004"]
    require(parameter(source, "./1/324/300").get("value") == "510000006", "Broken Source Media reference")
    require(parameter(source, "./2/321").get("value") == "3", "Effect Source type changed")
    require(parameter(source, "./2/311").get("value") == "1", "Effect Source Drop Zone changed")
    media = path.parent / "Drop Zone.tiff"
    require(media.is_file() and digest(media.read_bytes()) == PLACEHOLDER_SHA256, "Placeholder missing/changed")
    result = {"status": "structure_verified_native_loading_pending", "templateSHA256": digest(path.read_bytes()),
              "pluginVersion": plugin.get("pluginVersion"), "publications": [dict(x.attrib) for x in targets],
              "parameterPathsResolved": len(listed["parameters"]), "sourceMediaClosed": True,
              "mediaSHA256": PLACEHOLDER_SHA256, "customState": state,
              "nativeLoading": "pending user; no host executed"}
    return result, outer, inner


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    enc = sub.add_parser("encode", help="Wrap our own secure Custom Data archive and encode Motion text")
    enc.add_argument("--inner", type=Path, required=True)
    enc.add_argument("--text-output", type=Path, required=True)
    enc.add_argument("--outer-output", type=Path)
    chk = sub.add_parser("audit", help="Read-only template/archive/reference checks; native loading stays pending")
    chk.add_argument("template", type=Path)
    chk.add_argument("--parameters", type=Path)
    chk.add_argument("--json-output", type=Path)
    chk.add_argument("--inner-output", type=Path)
    chk.add_argument("--outer-output", type=Path)
    args = parser.parse_args()
    if args.command == "encode":
        inner = args.inner.read_bytes(); outer = wrap_inner(inner); text = encode_outer(outer)
        decoded_outer, decoded_inner, result = decode_text(text)
        require(decoded_inner == inner and decoded_outer == outer, "Own archive roundtrip failed")
        args.text_output.write_text(text + "\n")
        if args.outer_output:
            args.outer_output.write_bytes(outer)
    else:
        result, outer, inner = audit(args.template, args.parameters)
        if args.json_output:
            args.json_output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        if args.inner_output:
            args.inner_output.write_bytes(inner)
        if args.outer_output:
            args.outer_output.write_bytes(outer)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, IndexError, TypeError, OSError, ET.ParseError, plistlib.InvalidFileException) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
