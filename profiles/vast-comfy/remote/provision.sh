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

stage_number=0
stage_total=9
current_stage='startup'
stage() {
  stage_number=$((stage_number + 1))
  current_stage=$1
  printf '\n[%d/%d] %s\n' "$stage_number" "$stage_total" "$current_stage"
}
trap 'code=$?; echo "[FAILED] Stage: $current_stage (line $LINENO, exit $code)" >&2' ERR

stage 'Checking required commands and deployment configuration'
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

  echo "Downloading: $url"
  echo "Destination: $destination"
  curl --fail --silent --show-error --location --retry 6 --retry-delay 5 \
    --continue-at - --output "$partial" "$url" &
  local curl_pid=$!
  while kill -0 "$curl_pid" 2>/dev/null; do
    if [[ -e "$partial" ]]; then
      printf '[download] %s received for %s\n' "$(du -h "$partial" | awk '{print $1}')" "$(basename "$destination")"
    else
      printf '[download] waiting for %s\n' "$(basename "$destination")"
    fi
    sleep 10
  done
  if ! wait "$curl_pid"; then
    echo "Download failed: $url" >&2
    return 5
  fi
  if [[ -n "$expected_sha" ]]; then
    echo "Verifying SHA-256: $(basename "$destination")"
    if ! echo "$expected_sha  $partial" | sha256sum --check --status; then
      echo "Checksum verification failed: $partial" >&2
      exit 5
    fi
  fi
  mv "$partial" "$destination"
  echo "Download complete: $destination"
}

installation_mode=$(json_required '.comfyui.installation_mode')
comfy_repo=$(json_required '.comfyui.repository')
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

stage 'Preparing the pinned ComfyUI checkout on the persistent volume'
if [[ ! -d "$comfy_root/.git" ]]; then
  if [[ -e "$comfy_root" && ! -d "$comfy_root" ]]; then
    echo "$comfy_root exists but is not a directory; refusing to overwrite it." >&2
    exit 6
  fi
  if [[ -d "$comfy_root" && -n "$(find "$comfy_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "$comfy_root is not empty and is not a Git checkout; refusing to overwrite it." >&2
    exit 6
  fi
  echo "The persistent volume hides the image's original /workspace checkout."
  echo "Cloning pinned ComfyUI release $comfy_ref into $comfy_root."
  mkdir -p "$(dirname "$comfy_root")"
  git clone --progress --branch "$comfy_ref" --single-branch "$comfy_repo" "$comfy_root"
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

stage 'Verifying the image Python and CUDA runtime'
if ! "$comfy_python" -c 'import torch; assert torch.cuda.is_available()' >/dev/null 2>&1; then
  echo "The preinstalled image cannot access a CUDA-enabled PyTorch runtime." >&2
  exit 7
fi
"$comfy_python" -c 'import torch; print(f"PyTorch {torch.__version__}; CUDA available; GPU: {torch.cuda.get_device_name(0)}")'

stage 'Preparing persistent workspace directories'
mkdir -p /workspace/logs /workspace/bin "$project_root/workflows/original" "$project_root/records"

stage 'Downloading and verifying Anima model files'
while IFS=$'\t' read -r model_name model_folder model_url model_sha; do
  [[ -n "$model_name" && -n "$model_folder" && -n "$model_url" ]] || {
    echo "Invalid Anima model entry in configuration." >&2
    exit 8
  }
  download_file "$model_url" "$comfy_root/models/$model_folder/$model_name" "$model_sha"
done < <(jq -r '.anima.models[] | [.Name, .Folder, .Url, (.Sha256 // "")] | @tsv' "$deploy_config")

stage 'Installing the workflow and baseline record'
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

stage 'Restarting the ComfyUI Supervisor service'
supervisorctl status "$service_name" || true
supervisorctl restart "$service_name"

stage 'Waiting for the ComfyUI health endpoint'
health_url="http://${comfy_host}:${comfy_port}/system_stats"
healthy=false
for attempt in $(seq 1 60); do
  if curl --silent --fail "$health_url" >/dev/null; then
    healthy=true
    echo "ComfyUI is healthy: $health_url"
    break
  fi
  if (( attempt % 5 == 0 )); then
    echo "Still waiting for ComfyUI ($((attempt * 2)) seconds elapsed)..."
    supervisorctl status "$service_name" || true
  fi
  sleep 2
done
if [[ "$healthy" != true ]]; then
  echo "ComfyUI did not become healthy at $health_url" >&2
  supervisorctl tail -100 "$service_name" || true
  exit 9
fi

stage 'Installing and verifying Codex and the complete deployment'
if jq -e '.codex.install == true' "$deploy_config" >/dev/null; then
  bash "$(dirname "$0")/configure-codex.sh" "$deploy_config"
fi
bash "$(dirname "$0")/verify-deployment.sh" "$deploy_config"

echo "Preinstalled-image provisioning complete."
echo "ComfyUI release: $comfy_ref ($current_commit)"
echo "ComfyUI is bound to $comfy_host:$comfy_port and should be accessed through the SSH tunnel."
echo "Original workflow: $workflow_original"
echo "Baseline record: $project_root/records/anima-baseline.json"
