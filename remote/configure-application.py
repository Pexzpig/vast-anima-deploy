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


def link_details(link):
    if isinstance(link, dict):
        return (
            link.get("id"),
            link.get("origin_id"),
            link.get("origin_slot"),
            link.get("target_id"),
            link.get("target_slot"),
            link.get("type"),
        )
    if isinstance(link, list) and len(link) >= 6:
        return tuple(link[:6])
    raise ValueError("Unsupported ComfyUI link representation")


def link_fields(link):
    link_id, origin_id, _, target_id, _, _ = link_details(link)
    return link_id, origin_id, target_id


def named_input(node, name):
    return one(node.get("inputs", []), lambda item: item.get("name") == name, f"{name} input on node {node.get('id')}")


def named_output(node, name):
    return one(node.get("outputs", []), lambda item: item.get("name") == name, f"{name} output on node {node.get('id')}")


def next_numeric_id(items, field="id"):
    numeric = [item.get(field) for item in items if isinstance(item.get(field), int)]
    return max(numeric, default=0) + 1


def make_link(subgraph, origin_node, origin_slot, target_node, target_slot, value_type):
    links = subgraph.setdefault("links", [])
    link_id = max((link_details(link)[0] for link in links), default=0) + 1
    if links and isinstance(links[0], list):
        link = [link_id, origin_node["id"], origin_slot, target_node["id"], target_slot, value_type]
    else:
        link = {
            "id": link_id,
            "origin_id": origin_node["id"],
            "origin_slot": origin_slot,
            "target_id": target_node["id"],
            "target_slot": target_slot,
            "type": value_type,
        }
    links.append(link)
    target_node["inputs"][target_slot]["link"] = link_id
    output_links = origin_node["outputs"][origin_slot].setdefault("links", [])
    if output_links is None:
        origin_node["outputs"][origin_slot]["links"] = [link_id]
    elif link_id not in output_links:
        output_links.append(link_id)
    return link_id


def redirect_link_origin(subgraph, link_id, old_node, new_node, new_slot=0):
    link = one(subgraph.get("links", []), lambda item: link_details(item)[0] == link_id, f"link {link_id}")
    _, _, _, _, _, _ = link_details(link)
    for output in old_node.get("outputs", []):
        if link_id in (output.get("links") or []):
            output["links"] = [value for value in output.get("links", []) if value != link_id]
    output = new_node["outputs"][new_slot]
    output.setdefault("links", [])
    if output["links"] is None:
        output["links"] = []
    if link_id not in output["links"]:
        output["links"].append(link_id)
    if isinstance(link, dict):
        link["origin_id"] = new_node["id"]
        link["origin_slot"] = new_slot
    else:
        link[1] = new_node["id"]
        link[2] = new_slot


def lora_loader_node(node_id, title, file_name, strength, position):
    return {
        "id": node_id,
        "type": "LoraLoaderModelOnly",
        "pos": position,
        "size": [310, 130],
        "flags": {},
        "order": 0,
        "mode": 0,
        "inputs": [
            {"name": "model", "type": "MODEL", "link": None},
            {"name": "lora_name", "type": "COMBO", "widget": {"name": "lora_name"}, "link": None},
        ],
        "outputs": [{"name": "MODEL", "type": "MODEL", "links": []}],
        "title": title,
        "properties": {"Node name for S&R": "LoraLoaderModelOnly", "cnr_id": "comfy-core"},
        "widgets_values": [file_name, float(strength)],
    }


def expose_proxy_widget(workflow, subgraph, node_id, widget_name):
    instance = one(workflow.get("nodes", []), lambda node: node.get("type") == subgraph.get("id"), "Anima subgraph instance")
    proxies = instance.setdefault("properties", {}).setdefault("proxyWidgets", [])
    proxy = [str(node_id), widget_name]
    if proxy not in proxies:
        proxies.append(proxy)


def configure_model_chain(workflow, subgraph, config):
    nodes = subgraph.get("nodes", [])
    turbo = config["anima"]["turbo"]
    unet = one(nodes, lambda node: node.get("type") == "UNETLoader", "UNET loader")
    turbo_loader = one(
        nodes,
        lambda node: node.get("type") == "LoraLoaderModelOnly",
        "official Turbo LoRA loader",
    )
    model_switch = one(
        nodes,
        lambda node: node.get("type") == "ComfySwitchNode"
        and any(item.get("name") == "on_false" and item.get("type") == "MODEL" for item in node.get("inputs", [])),
        "Turbo model switch",
    )
    set_widget(turbo_loader, 0, str(turbo["name"]))
    set_widget(turbo_loader, 1, float(turbo["strength"]))

    turbo_input_link = named_input(turbo_loader, "model").get("link")
    base_switch_link = named_input(model_switch, "on_false").get("link")
    if turbo_input_link is None or base_switch_link is None:
        raise ValueError("Official Turbo model branch is not linked")

    chain_specs = []
    for item in config["anima"].get("managed_loras", []):
        if item.get("Enabled", False) and item.get("AutoApplyInComfyUI", True):
            chain_specs.append(
                (f"Managed {item['Kind'].title()} LoRA", str(item["Name"]), float(item["Strength"]), False)
            )
    manual_slots = int(config["anima"]["manual_lora_slots"])
    for index in range(manual_slots):
        role = "Character" if index == 0 else "Style" if index == 1 else f"Manual {index + 1}"
        chain_specs.append((f"{role} LoRA (select file, then set strength)", str(turbo["name"]), 0.0, True))

    source = unet
    next_node_id = next_numeric_id(nodes)
    for index, (title, file_name, strength, is_manual) in enumerate(chain_specs):
        loader = lora_loader_node(next_node_id, title, file_name, strength, [700 + index * 330, -260])
        next_node_id += 1
        nodes.append(loader)
        make_link(subgraph, source, 0, loader, 0, "MODEL")
        source = loader
        if is_manual:
            expose_proxy_widget(workflow, subgraph, loader["id"], "lora_name")
            expose_proxy_widget(workflow, subgraph, loader["id"], "strength_model")

    if source is not unet:
        redirect_link_origin(subgraph, turbo_input_link, unet, source)
        redirect_link_origin(subgraph, base_switch_link, unet, source)
    subgraph.setdefault("state", {})["lastNodeId"] = max(
        int(subgraph.get("state", {}).get("lastNodeId", 0)), next_node_id - 1
    )
    subgraph["state"]["lastLinkId"] = max(
        (link_details(link)[0] for link in subgraph.get("links", [])), default=0
    )
    return source


def build_standard_workflow(original, config):
    workflow = copy.deepcopy(original)
    baseline = config["anima"]["baseline"]
    turbo = config["anima"]["turbo"]
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
    for value_type, base_value, turbo_value in (
        ("INT", int(baseline["Steps"]), int(turbo["steps"])),
        ("FLOAT", float(baseline["Cfg"]), float(turbo["cfg"])),
    ):
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
        set_widget(source_node, 0, base_value)
        true_input = named_input(switch, "on_true")
        true_link = links.get(true_input.get("link"))
        if true_link is None:
            raise ValueError(f"Turbo {value_type} switch is not linked")
        _, turbo_origin_id, _ = link_fields(true_link)
        turbo_source = node_by_id.get(turbo_origin_id)
        if turbo_source is None:
            raise ValueError(f"Turbo {value_type} source node is missing")
        set_widget(turbo_source, 0, turbo_value)

    switch_control_links = {
        named_input(node, "switch").get("link")
        for node in nodes
        if node.get("type") == "ComfySwitchNode" and any(item.get("name") == "switch" for item in node.get("inputs", []))
    }
    turbo_boolean = one(
        nodes,
        lambda node: node.get("type") == "PrimitiveBoolean"
        and switch_control_links.issubset(set(named_output(node, "BOOLEAN").get("links") or [])),
        "Turbo mode boolean",
    )
    set_widget(turbo_boolean, 0, bool(turbo["enabled_by_default"]))

    model_source = configure_model_chain(workflow, subgraph, config)

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
    if str(turbo["name"]) not in serialized:
        raise ValueError("Managed workflow does not reference the configured Turbo LoRA")
    for item in config["anima"].get("managed_loras", []):
        if (
            item.get("Enabled", False)
            and item.get("AutoApplyInComfyUI", True)
            and str(item["Name"]) not in serialized
        ):
            raise ValueError(f"Managed workflow does not reference configured LoRA {item['Name']}")
    return workflow, model_source["id"]


def build_hires_workflow(standard, config, model_source_id):
    workflow = copy.deepcopy(standard)
    hires = config["anima"]["hires"]
    baseline = config["anima"]["baseline"]
    subgraph = one(
        workflow.get("definitions", {}).get("subgraphs", []),
        lambda item: item.get("name") == "Text to Image (Anima Base v1.0)",
        "Anima base subgraph",
    )
    nodes = subgraph.get("nodes", [])
    sampler = one(nodes, lambda node: node.get("type") == "KSampler", "first-pass KSampler")
    decoder = one(nodes, lambda node: node.get("type") == "VAEDecode", "VAE decoder")
    positive = one(nodes, lambda node: node.get("type") == "CLIPTextEncode" and "Positive Prompt" in node.get("title", ""), "positive prompt node")
    negative = one(nodes, lambda node: node.get("type") == "CLIPTextEncode" and "Negative Prompt" in node.get("title", ""), "negative prompt node")
    model_source = one(nodes, lambda node: node.get("id") == model_source_id, "non-Turbo LoRA model source")
    decoder_link = named_input(decoder, "samples").get("link")
    if decoder_link is None:
        raise ValueError("First-pass sampler is not linked to the VAE decoder")

    next_node_id = next_numeric_id(nodes)
    upscale = {
        "id": next_node_id,
        "type": "LatentUpscaleBy",
        "pos": [2050, 980],
        "size": [310, 100],
        "flags": {},
        "order": 0,
        "mode": 0,
        "inputs": [{"name": "samples", "type": "LATENT", "link": None}],
        "outputs": [{"name": "LATENT", "type": "LATENT", "links": []}],
        "title": "Hires latent upscale",
        "properties": {"Node name for S&R": "LatentUpscaleBy", "cnr_id": "comfy-core"},
        "widgets_values": [str(hires["upscale_method"]), float(hires["scale"])],
    }
    refiner = {
        "id": next_node_id + 1,
        "type": "KSampler",
        "pos": [2420, 920],
        "size": [310, 620],
        "flags": {},
        "order": 0,
        "mode": 0,
        "inputs": [
            {"name": "model", "type": "MODEL", "link": None},
            {"name": "positive", "type": "CONDITIONING", "link": None},
            {"name": "negative", "type": "CONDITIONING", "link": None},
            {"name": "latent_image", "type": "LATENT", "link": None},
        ],
        "outputs": [{"name": "LATENT", "type": "LATENT", "links": []}],
        "title": "Base hires refinement (Turbo excluded)",
        "properties": {"Node name for S&R": "KSampler", "cnr_id": "comfy-core"},
        "widgets_values": [
            int(baseline["Seed"]),
            "fixed",
            int(hires["steps"]),
            float(hires["cfg"]),
            str(hires["sampler"]),
            str(hires["scheduler"]),
            float(hires["denoise"]),
        ],
    }
    nodes.extend([upscale, refiner])
    redirect_link_origin(subgraph, decoder_link, sampler, refiner)
    make_link(subgraph, sampler, 0, upscale, 0, "LATENT")
    make_link(subgraph, model_source, 0, refiner, 0, "MODEL")
    make_link(subgraph, positive, 0, refiner, 1, "CONDITIONING")
    make_link(subgraph, negative, 0, refiner, 2, "CONDITIONING")
    make_link(subgraph, upscale, 0, refiner, 3, "LATENT")
    for node_id, widget_name in (
        (upscale["id"], "scale_by"),
        (refiner["id"], "steps"),
        (refiner["id"], "cfg"),
        (refiner["id"], "denoise"),
    ):
        expose_proxy_widget(workflow, subgraph, node_id, widget_name)
    subgraph.setdefault("state", {})["lastNodeId"] = max(
        int(subgraph.get("state", {}).get("lastNodeId", 0)), refiner["id"]
    )
    subgraph["state"]["lastLinkId"] = max(
        (link_details(link)[0] for link in subgraph.get("links", [])), default=0
    )
    return workflow


def configure_workflow(args) -> None:
    config = load_json(args.config)
    original = load_json(args.original)
    managed, model_source_id = build_standard_workflow(original, config)
    hires = build_hires_workflow(managed, config, model_source_id)
    write_json_atomic(args.managed, managed)
    write_json_atomic(args.installed, managed)
    write_json_atomic(args.hires_managed, hires)
    write_json_atomic(args.hires_installed, hires)


def verify_workflow(args) -> None:
    config = load_json(args.config)
    expected, model_source_id = build_standard_workflow(load_json(args.original), config)
    expected_hires = build_hires_workflow(expected, config, model_source_id)
    managed = load_json(args.managed)
    installed = load_json(args.installed)
    hires_managed = load_json(args.hires_managed)
    hires_installed = load_json(args.hires_installed)
    if managed != expected:
        raise ValueError("Managed workflow does not match the configured baseline")
    if installed != expected:
        raise ValueError("Installed ComfyUI workflow does not match the managed workflow")
    if hires_managed != expected_hires:
        raise ValueError("Managed hires workflow does not match the configured refinement settings")
    if hires_installed != expected_hires:
        raise ValueError("Installed ComfyUI hires workflow does not match the managed workflow")


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
    workflow.add_argument("hires_managed")
    workflow.add_argument("hires_installed")
    workflow.set_defaults(handler=configure_workflow)

    verify = subparsers.add_parser("verify-workflow")
    verify.add_argument("config")
    verify.add_argument("original")
    verify.add_argument("managed")
    verify.add_argument("installed")
    verify.add_argument("hires_managed")
    verify.add_argument("hires_installed")
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
