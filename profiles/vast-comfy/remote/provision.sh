#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/remote-config.json" >&2
  exit 2
fi

deploy_config=$1
if [[ ! -f "$deploy_config" ]]; then
  echo "Remote configuration not found: $deploy_config" >&2
  exit 2
fi

for required_command in jq git curl sha256sum supervisorctl; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Required command is missing from the vastai/comfy image: $required_command" >&2
    exit 3
  fi
done

json_required() {
  local query=$1
  local value
  value=$(jq -er "$query" "$deploy_config") || {
    echo "Missing required configuration value: $query" >&2
    exit 4
  }
  printf '%s' "$value"
}

download_file() {
  local url=$1
  local destination=$2
  local expected_sha=$3
  local partial="${destination}.part"

  mkdir -p "$(dirname "$destination")"
  if [[ -s "$destination" ]]; then
    if [[ -z "$expected_sha" ]] || echo "$expected_sha  $destination" | sha256sum --check --status; then
      echo "Already present: $destination"
      return
    fi
    echo "Checksum mismatch for existing file: $destination" >&2
    exit 5
  fi

  echo "Downloading $url"
  curl --fail --location --retry 6 --retry-delay 5 --continue-at - --output "$partial" "$url"
  if [[ -n "$expected_sha" ]] && ! echo "$expected_sha  $partial" | sha256sum --check --status; then
    echo "Checksum verification failed: $partial" >&2
    exit 5
  fi
  mv "$partial" "$destination"
}

installation_mode=$(json_required '.comfyui.installation_mode')
comfy_ref=$(json_required '.comfyui.ref')
comfy_root=$(json_required '.comfyui.root')
comfy_python=$(json_required '.comfyui.python')
comfy_host=$(json_required '.comfyui.listen_host')
comfy_port=$(json_required '.comfyui.port')
service_name=$(json_required '.comfyui.service_name')
project_root=$(json_required '.codex.project_root')

if [[ "$installation_mode" != 'preinstalled' ]]; then
  echo "This provisioner requires comfyui.installation_mode=preinstalled." >&2
  exit 6
fi
if [[ ! -d "$comfy_root/.git" ]]; then
  echo "Preinstalled ComfyUI checkout not found at $comfy_root." >&2
  echo "Use a fresh profile volume and a pinned vastai/comfy image." >&2
  exit 6
fi
if [[ ! -x "$comfy_python" ]]; then
  echo "Preinstalled Python environment not found: $comfy_python" >&2
  exit 6
fi

expected_commit=$(git -C "$comfy_root" rev-parse --verify "${comfy_ref}^{commit}" 2>/dev/null || true)
current_commit=$(git -C "$comfy_root" rev-parse HEAD)
if [[ -z "$expected_commit" || "$current_commit" != "$expected_commit" ]]; then
  echo "ComfyUI checkout does not match the pinned image release $comfy_ref." >&2
  echo "Current HEAD: $current_commit; expected: ${expected_commit:-missing ref}." >&2
  echo "Do not reuse a profile volume created by another image release." >&2
  exit 7
fi
if ! "$comfy_python" -c 'import torch; assert torch.cuda.is_available()' >/dev/null 2>&1; then
  echo "The preinstalled image cannot access a CUDA-enabled PyTorch runtime." >&2
  exit 7
fi

mkdir -p /workspace/logs /workspace/bin "$project_root/workflows/original" "$project_root/records"

while IFS=$'\t' read -r model_name model_folder model_url model_sha; do
  [[ -n "$model_name" && -n "$model_folder" && -n "$model_url" ]] || {
    echo "Invalid Anima model entry in configuration." >&2
    exit 8
  }
  download_file "$model_url" "$comfy_root/models/$model_folder/$model_name" "$model_sha"
done < <(jq -r '.anima.models[] | [.Name, .Folder, .Url, (.Sha256 // "")] | @tsv' "$deploy_config")

workflow_name=$(json_required '.anima.workflow_file_name')
workflow_url=$(json_required '.anima.workflow_url')
workflow_original="$project_root/workflows/original/$workflow_name"
download_file "$workflow_url" "$workflow_original" ''
mkdir -p "$comfy_root/user/default/workflows"
if [[ ! -e "$comfy_root/user/default/workflows/$workflow_name" ]]; then
  cp "$workflow_original" "$comfy_root/user/default/workflows/$workflow_name"
fi

jq '.anima.baseline' "$deploy_config" > "$project_root/records/anima-baseline.json"
cat > "$project_root/records/README.md" <<'EOF'
# Anima baseline record

This workspace uses the pinned vastai/comfy preinstalled-image profile. Keep
the original workflow unchanged, preserve generation metadata, and change one
prompt group, sampler parameter, or adapter weight at a time.
EOF

supervisorctl restart "$service_name"

health_url="http://${comfy_host}:${comfy_port}/system_stats"
healthy=false
for _ in $(seq 1 60); do
  if curl --silent --fail "$health_url" >/dev/null; then
    healthy=true
    break
  fi
  sleep 2
done
if [[ "$healthy" != true ]]; then
  echo "ComfyUI did not become healthy at $health_url" >&2
  supervisorctl tail -100 "$service_name" || true
  exit 9
fi

if jq -e '.codex.install == true' "$deploy_config" >/dev/null; then
  bash "$(dirname "$0")/configure-codex.sh" "$deploy_config"
fi

echo "Preinstalled-image provisioning complete."
echo "ComfyUI release: $comfy_ref ($current_commit)"
echo "ComfyUI is bound to $comfy_host:$comfy_port and should be accessed through the SSH tunnel."
echo "Original workflow: $workflow_original"
echo "Baseline record: $project_root/records/anima-baseline.json"
