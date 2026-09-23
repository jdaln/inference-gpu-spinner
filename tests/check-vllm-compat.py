#!/usr/bin/env python3
"""Check every model profile against the vLLM build its image actually pins.

The render tests prove a profile produces valid YAML. They cannot tell you whether the engine in
the pinned image knows the checkpoint's architecture, has the parsers the profile names, or accepts
the flags it passes — those only surface on a GPU you are already paying for. This reads vLLM's
source at the matching git ref and checks all three offline.

For each ansible/models/*.yml:
  1. the checkpoint's architecture (from the Hugging Face API) is in that ref's model registry
  2. every --reasoning-parser / --tool-call-parser value is registered at that ref
  3. every long CLI flag the profile passes appears in that ref's argument definitions

A registry hit means the code exists; the recipe says which version actually serves the model, and
it often states a higher floor than the release that first carried the architecture. Read the
recipe, then pin accordingly.

Usage:  python3 tests/check-vllm-compat.py [profile ...]
Needs network access to raw.githubusercontent.com, api.github.com and huggingface.co.
Responses are cached under tests/.vllm-compat-cache/ (gitignored); delete it to refetch.
"""

import json
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = ROOT / "tests/.vllm-compat-cache"
CACHE.mkdir(parents=True, exist_ok=True)

# Every image tag used by a profile (or by group_vars) maps to the vLLM git ref to inspect.
# Add a row here whenever a profile pins a new image, or the check cannot run for it.
TAG_TO_REF = {
    "v0.23.0-cu129-ubuntu2404": "v0.23.0",
    "v0.29.0-cu129-ubuntu2404": "v0.29.0",
    "cu129-nightly-cd10ed6f9f6b37a8ace9cf380007e66fe12ec0c3":
        "cd10ed6f9f6b37a8ace9cf380007e66fe12ec0c3",
    # Dedicated per-model launch images are built from a branch rather than a release, so there is
    # no tag to check against. main is the closest available superset.
    "deepseekv4-flash-vision": "main",
    "qwen38-flash-next": "main",
    "kimi-k3": "main",
    "glm53-flash": "main",
    # Same per-model build as glm53-flash, published as the CUDA 13 variant.
    "glm53-flash-x86_64-cu130": "main",
}

REGISTRY = "vllm/model_executor/models/registry.py"
REASONING = "vllm/reasoning/__init__.py"
TOOLS = "vllm/tool_parsers/__init__.py"
ARG_PATHS = re.compile(
    r"^vllm/(config/.*|engine/arg_utils"
    r"|entrypoints/(launchers/cli_args|openai/cli_args|cli/serve))\.py$"
)


def fetch(url, key):
    path = CACHE / key
    if path.exists():
        return path.read_text()
    try:
        body = urllib.request.urlopen(url, timeout=90).read().decode("utf-8", "replace")
    except Exception as exc:  # noqa: BLE001
        print(f"    (fetch failed: {url}: {exc})", file=sys.stderr)
        body = ""
    path.write_text(body)
    return body


def source(ref, path):
    return fetch(f"https://raw.githubusercontent.com/vllm-project/vllm/{ref}/{path}",
                 f"{ref.replace('/', '_')}__{path.replace('/', '_')}")


def arg_blob(ref):
    """Every file that declares CLI arguments at this ref, concatenated."""
    key = CACHE / f"{ref.replace('/', '_')}__argblob.py"
    if key.exists():
        return key.read_text()
    tree = fetch(f"https://api.github.com/repos/vllm-project/vllm/git/trees/{ref}?recursive=1",
                 f"{ref.replace('/', '_')}__tree.json")
    try:
        paths = [e["path"] for e in json.loads(tree)["tree"] if ARG_PATHS.match(e["path"])]
    except Exception:  # noqa: BLE001
        paths = ["vllm/engine/arg_utils.py"]
    blob = "\n".join(source(ref, p) for p in paths)
    key.write_text(blob)
    return blob


def architecture(repo_id):
    body = fetch(f"https://huggingface.co/api/models/{repo_id}",
                 "hf__" + repo_id.replace("/", "_") + ".json")
    try:
        return (json.loads(body).get("config", {}).get("architectures") or [None])[0]
    except Exception:  # noqa: BLE001
        return None


def parse_profile(path):
    raw = path.read_text()
    out = {"name": path.stem}
    for key in ("model_repo", "vllm_image_override"):
        match = re.search(rf'^{key}:\s*"([^"]+)"', raw, re.M)
        out[key] = match.group(1) if match else None
    out["flags"] = re.findall(r'^\s+-\s+["\']?(--[a-z0-9-]+)', raw, re.M)
    out["reasoning"] = re.findall(r'--reasoning-parser["\']?\s*\n\s+-\s+["\']?([a-z0-9_]+)', raw)
    out["tools"] = re.findall(r'--tool-call-parser["\']?\s*\n\s+-\s+["\']?([a-z0-9_]+)', raw)
    return out


def main(argv):
    global_image = re.search(r'^vllm_image:\s*"([^"]+)"',
                             (ROOT / "ansible/group_vars/all.yml").read_text(), re.M).group(1)
    wanted = set(argv[1:])
    failures = 0

    for path in sorted((ROOT / "ansible/models").glob("*.yml")):
        profile = parse_profile(path)
        if wanted and profile["name"] not in wanted:
            continue
        # A profile may pin "repo:tag@sha256:..." to hold a mutable tag still. The digest is what
        # docker resolves; the tag is what identifies the vLLM build, so map on the tag alone.
        tag = (profile["vllm_image_override"] or global_image).split(":", 1)[1].split("@", 1)[0]
        ref = TAG_TO_REF.get(tag)
        label = f"{profile['name']:<26} {tag}"

        if ref is None:
            print(f"  ?  {label}\n         no TAG_TO_REF entry — add one so this can be checked")
            failures += 1
            continue

        registry = source(ref, REGISTRY)
        reasoning = set(re.findall(r'"([a-z0-9_.]+)"', source(ref, REASONING)))
        tools = set(re.findall(r'"([a-z0-9_.]+)"', source(ref, TOOLS)))
        blob = arg_blob(ref)

        issues = []
        arch = architecture(profile["model_repo"]) if profile["model_repo"] else None
        if arch and f'"{arch}"' not in registry:
            issues.append(f"architecture {arch} is not in this ref's model registry")
        for name in profile["reasoning"]:
            if name not in reasoning:
                issues.append(f"reasoning parser '{name}' is not registered at this ref")
        for name in profile["tools"]:
            if name not in tools:
                issues.append(f"tool-call parser '{name}' is not registered at this ref")
        for flag in sorted(set(profile["flags"])):
            base = flag[2:]
            if base.startswith("no-"):        # argparse negation of --<base>
                base = base[3:]
            if f"--{base}" not in blob and base.replace("-", "_") not in blob:
                issues.append(f"flag {flag} is not defined at this ref")

        if issues:
            failures += 1
            print(f"  !  {label}")
            for issue in issues:
                print(f"         {issue}")
        else:
            print(f"  ok {label}  arch={arch}")

    print(f"\n{failures} profile(s) with findings")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
