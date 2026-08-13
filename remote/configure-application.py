#!/usr/bin/env python3
"""Deterministically configure managed application assets from remote-config.json."""

from __future__ import annotations

import argparse
import copy
import json
import os
import tempfile
from pathlib import Path


def load_json(path: str | Path):
    with open(path, "r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def write_json_atomic(path: str | Path, value) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, destination)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def one(nodes, predicate, description):
    matches = [node for node in nodes if predicate(node)]
    if len(matches) != 1:
        raise ValueError(f"Expected one {description}, found {len(matches)}")
    return matches[0]


def set_widget(node, index: int, value) -> None:
    widgets = node.get("widgets_values")
    if not isinstance(widgets, list) or len(widgets) <= index:
        raise ValueError(f"Node {node.get('id')} has no widget index {index}")
    widgets[index] = value


def link_fields(link):
    if isinstance(link, dict):
        return link.get("id"), link.get("origin_id"), link.get("target_id")
    if isinstance(link, list) and len(link) >= 4:
        return link[0], link[1], link[3]
    raise ValueError("Unsupported ComfyUI link representation")


def build_managed_workflow(original, config):
    workflow = copy.deepcopy(original)
    baseline = config["anima"]["baseline"]
    subgraphs = workflow.get("definitions", {}).get("subgraphs", [])
    subgraph = one(subgraphs, lambda item: item.get("name") == "Text to Image (Anima Base v1.0)", "Anima base subgraph")
    nodes = subgraph.get("nodes", [])
    node_by_id = {node.get("id"): node for node in nodes}

    positive = one(nodes, lambda node: node.get("type") == "CLIPTextEncode" and "Positive Prompt" in node.get("title", ""), "positive prompt node")
    negative = one(nodes, lambda node: node.get("type") == "CLIPTextEncode" and "Negative Prompt" in node.get("title", ""), "negative prompt node")
    latent = one(nodes, lambda node: node.get("type") == "EmptyLatentImage", "latent image node")
    sampler = one(nodes, lambda node: node.get("type") == "KSampler", "KSampler node")

    set_widget(positive, 0, str(baseline["PositivePrompt"]))
    set_widget(negative, 0, str(baseline["NegativePrompt"]))
    set_widget(latent, 0, int(baseline["Width"]))
    set_widget(latent, 1, int(baseline["Height"]))
    set_widget(sampler, 0, int(baseline["Seed"]))
    set_widget(sampler, 1, "fixed")
    set_widget(sampler, 2, int(baseline["Steps"]))
    set_widget(sampler, 3, float(baseline["Cfg"]))
    set_widget(sampler, 4, str(baseline["Sampler"]))
    set_widget(sampler, 5, str(baseline["Scheduler"]))

    links = {link_fields(link)[0]: link for link in subgraph.get("links", [])}
    for value_type, configured_value in (("INT", int(baseline["Steps"])), ("FLOAT", float(baseline["Cfg"]))):
        switch = one(
            nodes,
            lambda node: node.get("type") == "ComfySwitchNode"
            and any(item.get("name") == "on_false" and item.get("type") == value_type for item in node.get("inputs", [])),
            f"base {value_type} switch",
        )
        false_input = one(switch.get("inputs", []), lambda item: item.get("name") == "on_false", f"{value_type} on_false input")
        source_link = links.get(false_input.get("link"))
        if source_link is None:
            raise ValueError(f"Base {value_type} switch is not linked")
        _, origin_id, _ = link_fields(source_link)
        source_node = node_by_id.get(origin_id)
        if source_node is None:
            raise ValueError(f"Base {value_type} source node is missing")
        set_widget(source_node, 0, configured_value)

    for boolean_node in (node for node in nodes if node.get("type") == "PrimitiveBoolean"):
        set_widget(boolean_node, 0, False)

    selector_ids = {node.get("id") for node in workflow.get("nodes", []) if node.get("type") == "ResolutionSelector"}
    removed_link_ids = {
        link_fields(link)[0]
        for link in workflow.get("links", [])
        if link_fields(link)[1] in selector_ids
    }
    workflow["nodes"] = [node for node in workflow.get("nodes", []) if node.get("id") not in selector_ids]
    workflow["links"] = [link for link in workflow.get("links", []) if link_fields(link)[0] not in removed_link_ids]
    for node in workflow.get("nodes", []):
        for item in node.get("inputs", []):
            if item.get("link") in removed_link_ids:
                item["link"] = None

    serialized = json.dumps(workflow, ensure_ascii=False)
    for model in config["anima"]["models"]:
        if str(model["Name"]) not in serialized:
            raise ValueError(f"Managed workflow does not reference configured model {model['Name']}")
    return workflow


def configure_workflow(args) -> None:
    config = load_json(args.config)
    original = load_json(args.original)
    managed = build_managed_workflow(original, config)
    write_json_atomic(args.managed, managed)
    write_json_atomic(args.installed, managed)


def verify_workflow(args) -> None:
    config = load_json(args.config)
    expected = build_managed_workflow(load_json(args.original), config)
    managed = load_json(args.managed)
    installed = load_json(args.installed)
    if managed != expected:
        raise ValueError("Managed workflow does not match the configured baseline")
    if installed != expected:
        raise ValueError("Installed ComfyUI workflow does not match the managed workflow")


def merge_webui_settings(config, settings):
    webui = config["webui"]
    if not isinstance(settings, dict):
        raise ValueError("WebUI config.json must contain a JSON object")
    managed_names = {str(extension["Name"]) for extension in webui["extensions"] if extension.get("Enabled", False)}
    disabled = settings.get("disabled_extensions", [])
    if not isinstance(disabled, list):
        disabled = []
    settings["disabled_extensions"] = [name for name in disabled if name not in managed_names]
    settings["disable_all_extensions"] = "none"
    settings["localization"] = str(webui["localization"])
    return settings


def configure_webui(args) -> None:
    config = load_json(args.config)
    path = Path(args.webui_config)
    settings = load_json(path) if path.is_file() else {}
    settings = merge_webui_settings(config, settings)
    write_json_atomic(path, settings)


def prepare_webui(args) -> None:
    """Avoid pre-creating config.json before Forge writes its version marker."""
    config = load_json(args.config)
    path = Path(args.webui_config)
    if not path.is_file():
        print("deferred")
        return

    settings = load_json(path)
    managed_bootstrap = merge_webui_settings(config, {})
    if settings == managed_bootstrap:
        backup_directory = Path(args.backup_directory)
        backup_directory.mkdir(parents=True, exist_ok=True)
        backup = backup_directory / "webui-config.pre-first-start.json"
        suffix = 1
        while backup.exists():
            backup = backup_directory / f"webui-config.pre-first-start.{suffix}.json"
            suffix += 1
        os.replace(path, backup)
        print(f"deferred:{backup}")
        return

    write_json_atomic(path, merge_webui_settings(config, settings))
    print("configured")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    workflow = subparsers.add_parser("configure-workflow")
    workflow.add_argument("config")
    workflow.add_argument("original")
    workflow.add_argument("managed")
    workflow.add_argument("installed")
    workflow.set_defaults(handler=configure_workflow)

    verify = subparsers.add_parser("verify-workflow")
    verify.add_argument("config")
    verify.add_argument("original")
    verify.add_argument("managed")
    verify.add_argument("installed")
    verify.set_defaults(handler=verify_workflow)

    webui = subparsers.add_parser("configure-webui")
    webui.add_argument("config")
    webui.add_argument("webui_config")
    webui.set_defaults(handler=configure_webui)

    prepare = subparsers.add_parser("prepare-webui")
    prepare.add_argument("config")
    prepare.add_argument("webui_config")
    prepare.add_argument("backup_directory")
    prepare.set_defaults(handler=prepare_webui)

    arguments = parser.parse_args()
    arguments.handler(arguments)


if __name__ == "__main__":
    main()
