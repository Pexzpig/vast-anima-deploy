#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 /path/to/remote-config.json" >&2
  exit 2
fi

deploy_config=$1
secret_directory=$(dirname "$deploy_config")
civitai_token_file="$secret_directory/.civitai-token"
civitai_curl_config="$secret_directory/.civitai-curl.conf"
cleanup_secrets() {
  rm -f -- "$civitai_token_file" "$civitai_curl_config"
}
trap cleanup_secrets EXIT
if [[ -s "$civitai_token_file" ]]; then
  IFS= read -r civitai_token < "$civitai_token_file"
  if [[ ! "$civitai_token" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo 'Civitai token contains unsupported characters.' >&2
    exit 2
  fi
  umask 077
  printf 'header = "Authorization: Bearer %s"\n' "$civitai_token" > "$civitai_curl_config"
  unset civitai_token
  rm -f -- "$civitai_token_file"
fi
stage_number=0
stage_total=11
current_stage='startup'
stage() {
  stage_number=$((stage_number + 1))
  current_stage=$1
  printf '\n[%d/%d] %s\n' "$stage_number" "$stage_total" "$current_stage"
}
trap 'code=$?; echo "[FAILED] Stage: $current_stage (line $LINENO, exit $code)" >&2' ERR

stage 'Locating and validating the PyTorch base environment'
configured_python=$(sed -n 's/.*"python"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$deploy_config" | head -1)
base_python=${configured_python:-/venv/main/bin/python}
if [[ ! -x "$base_python" ]]; then
  base_python=$(command -v python3 || command -v python || true)
fi
if [[ -z "$base_python" || ! -x "$base_python" ]]; then
  echo 'The vastai/pytorch image did not provide an executable Python runtime.' >&2
  exit 3
fi

application_type=$(
  "$base_python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["application"]["type"])' "$deploy_config"
)
if [[ "$application_type" != 'comfyui' && "$application_type" != 'webui' ]]; then
  echo "Unsupported application type: $application_type" >&2
  exit 3
fi

"$base_python" - <<'PY'
import torch
assert torch.cuda.is_available(), 'torch.cuda.is_available() is false'
print(f'Base PyTorch: {torch.__version__}')
print(f'Base CUDA runtime: {torch.version.cuda}')
print(f'GPU: {torch.cuda.get_device_name(0)}')
PY
minimum_cuda=$("$base_python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["pytorch"]["minimum_cuda_version"])' "$deploy_config")
"$base_python" - "$minimum_cuda" <<'PY'
import sys
import torch

minimum = tuple(int(part) for part in sys.argv[1].split('.')[:2])
actual_text = torch.version.cuda or '0.0'
actual = tuple(int(part) for part in actual_text.split('.')[:2])
assert actual >= minimum, f'CUDA runtime {actual_text} is below required {sys.argv[1]}'
PY

stage 'Installing required Ubuntu packages'
export DEBIAN_FRONTEND=noninteractive
mapfile -t system_packages < <(
  "$base_python" -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["system"]["packages"]))' "$deploy_config"
)
apt-get update
apt-get install -y --no-install-recommends \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  "${system_packages[@]}"

for required_command in jq git curl sha256sum supervisorctl supervisord; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Required command is missing after package setup: $required_command" >&2
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
  local source=${4:-direct}
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
  local -a curl_arguments=(
    --fail --silent --show-error --location --retry 6 --retry-delay 5
    --continue-at - --output "$partial"
  )
  if [[ "$source" == 'civitai' && -s "$civitai_curl_config" ]]; then
    curl_arguments+=(--config "$civitai_curl_config")
  fi
  curl "${curl_arguments[@]}" "$url" &
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
    if [[ "$source" == 'civitai' ]]; then
      if [[ -s "$civitai_curl_config" ]]; then
        echo 'Authenticated Civitai download failed. Re-enter or replace the Civitai API Key from the ManageLoRA menu, then provision again.' >&2
      else
        echo 'Civitai download failed. If this resource requires login, save a Civitai API Key from the ManageLoRA menu and provision again.' >&2
      fi
    fi
    return 1
  fi
  if [[ -n "$expected_sha" ]]; then
    echo "Verifying SHA-256: $(basename "$destination")"
    echo "$expected_sha  $partial" | sha256sum --check --status || {
      echo "Checksum verification failed: $partial" >&2
      exit 5
    }
  fi
  mv "$partial" "$destination"
  echo "Download complete: $destination"
}

checkout_repository() {
  local repository=$1
  local ref=$2
  local root=$3

  if [[ -d "$root/.git" ]]; then
    echo "Using existing checkout: $root"
    git -C "$root" fetch --tags origin "$ref"
    git -C "$root" checkout "$ref"
    if git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
      git -C "$root" reset --keep "origin/$ref"
    fi
  elif [[ -e "$root" && -n "$(find "$root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    echo "$root is non-empty and is not a Git checkout; refusing to overwrite it." >&2
    exit 6
  else
    mkdir -p "$(dirname "$root")"
    git clone --progress --branch "$ref" --single-branch "$repository" "$root"
  fi
}

checkout_pinned_repository() {
  local repository=$1
  local commit=$2
  local root=$3

  [[ "$commit" =~ ^[0-9a-fA-F]{40}$ ]] || { echo "Pinned application commit is invalid: $commit" >&2; exit 6; }
  if [[ -d "$root/.git" ]]; then
    local existing_origin
    existing_origin=$(git -C "$root" remote get-url origin 2>/dev/null || true)
    if [[ "$existing_origin" != "$repository" ]]; then
      echo "Application checkout $root has unexpected origin: ${existing_origin:-missing}" >&2
      exit 6
    fi
    echo "Using existing pinned checkout: $root"
  elif [[ -e "$root" && -n "$(find "$root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    echo "$root is non-empty and is not a Git checkout; refusing to overwrite it." >&2
    exit 6
  else
    mkdir -p "$(dirname "$root")"
    git clone --filter=blob:none --no-checkout "$repository" "$root"
  fi

  git -C "$root" fetch --no-tags origin "$commit"
  git -C "$root" checkout --detach --force "$commit"
  local actual_commit
  actual_commit=$(git -C "$root" rev-parse HEAD)
  if [[ "$actual_commit" != "$commit" ]]; then
    echo "Pinned application checkout mismatch at $root: $actual_commit != $commit" >&2
    exit 6
  fi
}

checkout_managed_repository() {
  local repository=$1
  local commit=$2
  local root=$3

  if [[ -d "$root/.git" ]]; then
    local existing_origin
    existing_origin=$(git -C "$root" remote get-url origin 2>/dev/null || true)
    if [[ "$existing_origin" != "$repository" ]]; then
      echo "Managed extension $root has unexpected origin: ${existing_origin:-missing}" >&2
      exit 6
    fi
    echo "Updating managed extension: $root"
  elif [[ -e "$root" && -n "$(find "$root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    echo "$root is non-empty and is not the managed Git checkout; refusing to overwrite it." >&2
    exit 6
  else
    mkdir -p "$(dirname "$root")"
    git clone --filter=blob:none --no-checkout "$repository" "$root"
  fi

  git -C "$root" fetch --no-tags origin "$commit"
  git -C "$root" checkout --detach --force "$commit"
  local actual_commit
  actual_commit=$(git -C "$root" rev-parse HEAD)
  if [[ "$actual_commit" != "$commit" ]]; then
    echo "Managed extension checkout mismatch at $root: $actual_commit != $commit" >&2
    exit 6
  fi
}

stage 'Installing uv and preparing workspace directories'
"$base_python" -m pip install --upgrade uv
uv_bin=$(command -v uv || true)
if [[ -z "$uv_bin" && -x "$(dirname "$base_python")/uv" ]]; then
  uv_bin="$(dirname "$base_python")/uv"
fi
if [[ -z "$uv_bin" ]]; then
  echo 'uv installation completed but the executable could not be located.' >&2
  exit 6
fi
project_root=$(json_required '.codex.project_root')
mkdir -p /workspace/logs /workspace/bin /workspace/venvs "$project_root/records"

stage "Preparing the selected application: $application_type"
webui_configuration_deferred=false
if [[ "$application_type" == 'comfyui' ]]; then
  app_repo=$(json_required '.comfyui.repository')
  app_ref=$(json_required '.comfyui.ref')
  app_root=$(json_required '.comfyui.root')
  app_venv=$(json_required '.comfyui.venv')
  app_python=$(json_required '.comfyui.python')
  app_torch_version=$(json_required '.comfyui.torch_version')
  app_torchvision_version=$(json_required '.comfyui.torchvision_version')
  app_torchaudio_version=$(json_required '.comfyui.torchaudio_version')
  app_torch_cuda_version=$(json_required '.comfyui.torch_cuda_version')
  app_torch_index_url=$(json_required '.comfyui.torch_index_url')
  app_host=$(json_required '.comfyui.listen_host')
  app_port=$(json_required '.comfyui.port')
  service_name=$(json_required '.comfyui.service_name')
  log_path=$(json_required '.comfyui.log_path')

  checkout_repository "$app_repo" "$app_ref" "$app_root"
  if [[ "$app_venv" != /workspace/venvs/* || "$app_venv" == '/workspace/venvs/' || "$app_python" != "$app_venv/bin/python" ]]; then
    echo "Unsafe managed ComfyUI virtual environment path: $app_venv" >&2
    exit 6
  fi

  comfyui_environment_matches() {
    [[ -x "$app_python" ]] || return 1
    "$app_python" - "$app_torch_version" "$app_torchvision_version" "$app_torchaudio_version" "$app_torch_cuda_version" <<'PY'
import importlib.metadata
import sys
import torch

expected_torch, expected_torchvision, expected_torchaudio, expected_cuda = sys.argv[1:]
assert torch.__version__.split("+", 1)[0] == expected_torch
assert importlib.metadata.version("torchvision").split("+", 1)[0] == expected_torchvision
assert importlib.metadata.version("torchaudio").split("+", 1)[0] == expected_torchaudio
assert torch.version.cuda == expected_cuda, f"torch CUDA {torch.version.cuda} != {expected_cuda}"
assert torch.cuda.is_available(), "ComfyUI PyTorch cannot access the GPU"
PY
  }

  comfyui_environment_ready=false
  if comfyui_environment_matches >/dev/null 2>&1; then
    comfyui_environment_ready=true
    echo "Reusing validated managed ComfyUI environment: $app_venv"
  elif [[ -e "$app_venv" ]]; then
    echo "Rebuilding incompatible managed ComfyUI environment: $app_venv"
    rm -rf -- "$app_venv"
  fi
  if [[ "$comfyui_environment_ready" != true ]]; then
    "$uv_bin" venv "$app_venv" --python "$base_python" --seed
    "$uv_bin" pip install --python "$app_python" --index-url "$app_torch_index_url" \
      "torch==$app_torch_version" "torchvision==$app_torchvision_version" "torchaudio==$app_torchaudio_version"
  fi

  comfy_requirements="$app_root/requirements.txt"
  comfy_managed_requirements="$project_root/records/comfyui-requirements-managed.txt"
  comfy_pytorch_constraints="$project_root/records/comfyui-pytorch-constraints.txt"
  for managed_package in torch torchvision torchaudio; do
    if ! grep -Eq "^${managed_package}([[:space:]]*(#.*)?)?$" "$comfy_requirements"; then
      echo "ComfyUI requirements no longer contain the expected unpinned package: $managed_package" >&2
      exit 6
    fi
  done
  awk '!/^(torch|torchvision|torchaudio)([[:space:]]*(#.*)?)?$/' \
    "$comfy_requirements" > "$comfy_managed_requirements"
  printf 'torch==%s\ntorchvision==%s\ntorchaudio==%s\n' \
    "$app_torch_version" "$app_torchvision_version" "$app_torchaudio_version" > "$comfy_pytorch_constraints"
  "$uv_bin" pip install --python "$app_python" \
    --constraint "$comfy_pytorch_constraints" -r "$comfy_managed_requirements"
  comfyui_environment_matches || {
    echo "Pinned ComfyUI PyTorch environment failed validation after installing application requirements." >&2
    exit 6
  }
else
  app_repo=$(json_required '.webui.repository')
  app_ref=$(json_required '.webui.commit')
  app_root=$(json_required '.webui.root')
  app_venv=$(json_required '.webui.venv')
  app_python=$(json_required '.webui.python')
  app_python_version=$(json_required '.webui.python_version')
  app_torch_version=$(json_required '.webui.torch_version')
  app_torchvision_version=$(json_required '.webui.torchvision_version')
  app_torch_cuda_version=$(json_required '.webui.torch_cuda_version')
  app_torch_index_url=$(json_required '.webui.torch_index_url')
  app_host=$(json_required '.webui.listen_host')
  app_port=$(json_required '.webui.port')
  service_name=$(json_required '.webui.service_name')
  log_path=$(json_required '.webui.log_path')

  checkout_pinned_repository "$app_repo" "$app_ref" "$app_root"
  export UV_PYTHON_INSTALL_DIR=/workspace/.uv/python
  if [[ "$app_venv" != /workspace/venvs/* || "$app_venv" == '/workspace/venvs/' || "$app_python" != "$app_venv/bin/python" ]]; then
    echo "Unsafe managed WebUI virtual environment path: $app_venv" >&2
    exit 6
  fi

  webui_environment_matches() {
    [[ -x "$app_python" ]] || return 1
    "$app_python" - "$app_python_version" "$app_torch_version" "$app_torchvision_version" "$app_torch_cuda_version" <<'PY'
import importlib.metadata
import sys
import torch

expected_python, expected_torch, expected_torchvision, expected_cuda = sys.argv[1:]
actual_python = f"{sys.version_info.major}.{sys.version_info.minor}"
actual_torch = torch.__version__.split("+", 1)[0]
actual_torchvision = importlib.metadata.version("torchvision").split("+", 1)[0]
assert actual_python == expected_python, f"Python {actual_python} != {expected_python}"
assert actual_torch == expected_torch, f"torch {actual_torch} != {expected_torch}"
assert actual_torchvision == expected_torchvision, f"torchvision {actual_torchvision} != {expected_torchvision}"
assert torch.version.cuda == expected_cuda, f"torch CUDA {torch.version.cuda} != {expected_cuda}"
assert torch.cuda.is_available(), "WebUI PyTorch cannot access the GPU"
PY
  }

  webui_environment_ready=false
  if webui_environment_matches >/dev/null 2>&1; then
    webui_environment_ready=true
    echo "Reusing validated managed WebUI environment: $app_venv"
  elif [[ -e "$app_venv" ]]; then
    echo "Rebuilding incompatible managed WebUI environment: $app_venv"
    rm -rf -- "$app_venv"
  fi
  if [[ "$webui_environment_ready" != true ]]; then
    "$uv_bin" python install "$app_python_version"
    "$uv_bin" venv "$app_venv" --python "$app_python_version" --seed
    "$uv_bin" pip install --python "$app_python" --index-url "$app_torch_index_url" \
      "torch==$app_torch_version" "torchvision==$app_torchvision_version"
    webui_environment_matches || {
      echo "Pinned WebUI PyTorch environment failed validation." >&2
      exit 6
    }
  fi
  mkdir -p "$app_root/models/Stable-diffusion" "$app_root/models/text_encoder" "$app_root/models/VAE"
  while IFS=$'\t' read -r extension_name extension_repository extension_commit; do
    [[ "$extension_name" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe managed extension name: $extension_name" >&2; exit 6; }
    checkout_managed_repository "$extension_repository" "$extension_commit" "$app_root/extensions/$extension_name"
  done < <(jq -r '.webui.extensions[] | select(.Enabled == true) | [.Name, .Repository, .Commit] | @tsv' "$deploy_config")
  webui_prepare_result=$("$base_python" "$(dirname "$0")/configure-application.py" prepare-webui \
    "$deploy_config" "$app_root/config.json" "$project_root/records")
  if [[ "$webui_prepare_result" == deferred* ]]; then
    webui_configuration_deferred=true
    if [[ "$webui_prepare_result" == deferred:* ]]; then
      echo "Preserved the premature WebUI config as: ${webui_prepare_result#deferred:}"
    fi
    echo 'Deferring managed WebUI settings until Forge creates its versioned config.json.'
  fi
  chmod 0755 "$app_root/webui.sh" "$app_root/webui-user.sh" 2>/dev/null || true
fi

stage 'Verifying the selected application Python environment'
if [[ "$application_type" == 'comfyui' ]]; then
  "$app_python" - <<'PY'
import importlib.metadata
import torch
assert torch.cuda.is_available(), 'application torch cannot access CUDA'
print(
    'ComfyUI environment: '
    f'torch={torch.__version__}, '
    f'torchvision={importlib.metadata.version("torchvision")}, '
    f'torchaudio={importlib.metadata.version("torchaudio")}, '
    f'cuda={torch.version.cuda}, gpu={torch.cuda.get_device_name(0)}'
)
PY
else
  "$app_python" - <<'PY'
import importlib.metadata
import torch
assert torch.cuda.is_available(), 'Forge PyTorch cannot access CUDA'
print(f'Forge environment: torch={torch.__version__}, torchvision={importlib.metadata.version("torchvision")}, cuda={torch.version.cuda}, gpu={torch.cuda.get_device_name(0)}')
PY
fi

stage 'Downloading and verifying Anima model files'
while IFS=$'\t' read -r model_name comfy_folder webui_folder model_url model_sha; do
  if [[ "$application_type" == 'comfyui' ]]; then
    model_destination="$app_root/models/$comfy_folder/$model_name"
  else
    model_destination="$app_root/models/$webui_folder/$model_name"
  fi
  download_file "$model_url" "$model_destination" "$model_sha"
done < <(jq -r '.anima.models[] | [.Name, .ComfyFolder, .WebUiFolder, .Url, (.Sha256 // "")] | @tsv' "$deploy_config")
if [[ "$application_type" == 'comfyui' ]]; then
  lora_root="$app_root/models/loras"
  turbo_name=$(json_required '.anima.turbo.name')
  turbo_url=$(json_required '.anima.turbo.url')
  turbo_sha=$(json_required '.anima.turbo.sha256')
  download_file "$turbo_url" "$lora_root/$turbo_name" "$turbo_sha"
else
  lora_root="$app_root/models/Lora"
fi
mkdir -p "$lora_root"
while IFS=$'\t' read -r lora_name lora_url lora_sha lora_source; do
  download_file "$lora_url" "$lora_root/$lora_name" "$lora_sha" "$lora_source"
done < <(jq -r '.anima.managed_loras[] | select(.Enabled == true) | [.Name, .Url, .Sha256, .Source] | @tsv' "$deploy_config")
local_lora_installer="$secret_directory/remote/install-local-loras.py"
if [[ ! -f "$local_lora_installer" ]]; then
  echo "Local LoRA installer is missing: $local_lora_installer" >&2
  exit 5
fi
"$base_python" "$local_lora_installer" install "$deploy_config" "$lora_root" "$secret_directory/local-loras"
rm -f -- "$civitai_curl_config"

stage 'Installing application workflow or baseline configuration'
mkdir -p "$project_root/workflows/original"
workflow_name=$(json_required '.anima.workflow_file_name')
if [[ "$application_type" == 'comfyui' ]]; then
  workflow_url=$(json_required '.anima.workflow_url')
  workflow_sha=$(json_required '.anima.workflow_sha256')
  managed_workflow_name=$(json_required '.anima.managed_workflow_file_name')
  hires_workflow_name=$(json_required '.anima.hires_workflow_file_name')
  workflow_original="$project_root/workflows/original/$workflow_name"
  workflow_managed="$project_root/workflows/$managed_workflow_name"
  workflow_installed="$app_root/user/default/workflows/$managed_workflow_name"
  hires_workflow_managed="$project_root/workflows/$hires_workflow_name"
  hires_workflow_installed="$app_root/user/default/workflows/$hires_workflow_name"
  if [[ -s "$workflow_original" ]] && ! echo "$workflow_sha  $workflow_original" | sha256sum --check --status; then
    workflow_backup="${workflow_original}.pre-pinned.$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$workflow_original" "$workflow_backup"
    echo "Preserved the previous unpinned workflow as: $workflow_backup"
  fi
  download_file "$workflow_url" "$workflow_original" "$workflow_sha"
  mkdir -p "$app_root/user/default/workflows"
  "$base_python" "$(dirname "$0")/configure-application.py" configure-workflow \
    "$deploy_config" "$workflow_original" "$workflow_managed" "$workflow_installed" \
    "$hires_workflow_managed" "$hires_workflow_installed"
else
  workflow_original='not used by Forge WebUI'
fi
jq '.anima.baseline' "$deploy_config" > "$project_root/records/anima-baseline.json"
jq -n --arg application "$application_type" --arg repository "$app_repo" --arg ref "$app_ref" \
  '{application:$application, repository:$repository, ref:$ref}' > "$project_root/records/deployment-application.json"

stage "Configuring the $service_name Supervisor service"
start_script="/workspace/bin/start-${service_name}.sh"
if [[ "$application_type" == 'comfyui' ]]; then
  {
    echo '#!/usr/bin/env bash'
    echo 'set -Eeuo pipefail'
    printf 'cd %q\n' "$app_root"
    printf 'exec %q main.py --listen %q --port %q' "$app_python" "$app_host" "$app_port"
    while IFS= read -r argument; do printf ' %q' "$argument"; done < <(jq -r '.comfyui.extra_args[]?' "$deploy_config")
    printf '\n'
  } > "$start_script"
else
  {
    echo '#!/usr/bin/env bash'
    echo 'set -Eeuo pipefail'
    printf 'cd %q\n' "$app_root"
    printf 'export VIRTUAL_ENV=%q\n' "$app_venv"
    printf 'export PATH=%q:"$PATH"\n' "$app_venv/bin"
    printf 'export python_cmd=%q\n' "$app_python"
    printf 'export venv_dir=%q\n' "$app_venv"
    printf 'export TORCH_INDEX_URL=%q\n' "$app_torch_index_url"
    printf 'export TORCH_COMMAND=%q\n' "pip install torch==$app_torch_version torchvision==$app_torchvision_version --index-url $app_torch_index_url"
    printf 'exec %q launch.py --port %q' "$app_python" "$app_port"
    while IFS= read -r argument; do printf ' %q' "$argument"; done < <(jq -r '.webui.extra_args[]?' "$deploy_config")
    printf '\n'
  } > "$start_script"
fi
chmod 0755 "$start_script"

mkdir -p "$(dirname "$log_path")" /var/log/supervisor /var/run
cat > "/etc/supervisor/conf.d/${service_name}.conf" <<EOF
[program:$service_name]
command=$start_script
directory=$app_root
autostart=true
autorestart=true
startsecs=5
stopasgroup=true
killasgroup=true
stdout_logfile=$log_path
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=2
redirect_stderr=true
EOF

if ! supervisorctl pid >/dev/null 2>&1; then
  pgrep -x supervisord >/dev/null 2>&1 || supervisord -c /etc/supervisor/supervisord.conf
  for _ in $(seq 1 15); do supervisorctl pid >/dev/null 2>&1 && break; sleep 2; done
fi
supervisorctl pid >/dev/null 2>&1 || { echo 'Supervisor did not become ready.' >&2; exit 7; }
supervisorctl reread
supervisorctl update
supervisorctl restart "$service_name"

onstart_script=/root/onstart.sh
onstart_marker='# anima-vast-deploy: restore supervisor'
touch "$onstart_script"
if ! grep -Fq "$onstart_marker" "$onstart_script"; then
  cat >> "$onstart_script" <<'EOF'

# anima-vast-deploy: restore supervisor
if command -v supervisorctl >/dev/null 2>&1 && ! supervisorctl pid >/dev/null 2>&1; then
  mkdir -p /var/log/supervisor /var/run
  supervisord -c /etc/supervisor/supervisord.conf
fi
EOF
  chmod 0755 "$onstart_script"
fi

stage "Waiting for the $application_type health endpoint"
health_url="http://${app_host}:${app_port}"
if [[ "$application_type" == 'comfyui' ]]; then health_url+='/system_stats'; fi
wait_for_application_health() {
  local context=${1:-}
  local healthy=false
  local attempt
  for attempt in $(seq 1 450); do
    if curl --silent --fail --max-time 5 "$health_url" >/dev/null; then
      healthy=true
      echo "$application_type is healthy${context}: $health_url"
      break
    fi
    supervisor_state=$(supervisorctl status "$service_name" 2>/dev/null | awk '{print $2}' || true)
    if [[ "$supervisor_state" == 'FATAL' || "$supervisor_state" == 'EXITED' ]]; then
      echo "$service_name entered $supervisor_state while waiting for its health endpoint." >&2
      tail -n 120 "$log_path" 2>/dev/null || true
      return 1
    fi
    if (( attempt % 10 == 0 )); then
      echo "Still waiting for $application_type${context} ($((attempt * 2)) seconds elapsed)..."
      supervisorctl status "$service_name" || true
      tail -n 8 "$log_path" 2>/dev/null || true
    fi
    sleep 2
  done
  if [[ "$healthy" != true ]]; then
    echo "$application_type did not become healthy${context} at $health_url" >&2
    tail -n 120 "$log_path" 2>/dev/null || true
    return 1
  fi
}

wait_for_application_health
if [[ "$application_type" == 'webui' && "$webui_configuration_deferred" == true ]]; then
  "$base_python" "$(dirname "$0")/configure-application.py" configure-webui "$deploy_config" "$app_root/config.json"
  echo 'Managed WebUI extensions and localization were applied after Forge initialization; restarting once.'
  supervisorctl restart "$service_name"
  wait_for_application_health ' after managed configuration'
fi

stage 'Installing Codex CLI and project configuration'
if jq -e '.codex.install == true' "$deploy_config" >/dev/null; then
  bash "$(dirname "$0")/configure-codex.sh" "$deploy_config"
fi

stage 'Running complete deployment verification'
bash "$(dirname "$0")/verify-deployment.sh" "$deploy_config"

manifest_path=/workspace/anima-project/records/vast-anima-deploy-manifest.json
mkdir -p "$(dirname "$manifest_path")"
manifest_temporary="${manifest_path}.tmp"
jq -n \
  --arg created_by 'vast-anima-deploy' \
  --arg application_type "$application_type" \
  --arg deployment_image "$(json_required '.deployment_image')" \
  --arg service_name "$service_name" \
  --arg listen_host "$app_host" \
  --argjson remote_port "$app_port" \
  --argjson local_port "$(json_required ".${application_type}.local_port")" \
  --arg application_root "$app_root" \
  --arg verified_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{schema_version:1, created_by:$created_by, application_type:$application_type,
    deployment_image:$deployment_image, service_name:$service_name,
    listen_host:$listen_host, remote_port:$remote_port, local_port:$local_port,
    application_root:$application_root, verified_at:$verified_at}' > "$manifest_temporary"
mv "$manifest_temporary" "$manifest_path"

echo "PyTorch-based $application_type provisioning complete."
echo "Application root: $app_root"
echo "Application endpoint: $health_url"
echo "Codex project: $project_root"
