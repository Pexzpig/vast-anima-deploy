#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 /path/to/remote-config.json" >&2
  exit 2
fi

deploy_config=$1
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
apt-get install -y --no-install-recommends "${system_packages[@]}"

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
  wait "$curl_pid"
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
if [[ "$application_type" == 'comfyui' ]]; then
  app_repo=$(json_required '.comfyui.repository')
  app_ref=$(json_required '.comfyui.ref')
  app_root=$(json_required '.comfyui.root')
  app_venv=$(json_required '.comfyui.venv')
  app_python=$(json_required '.comfyui.python')
  app_host=$(json_required '.comfyui.listen_host')
  app_port=$(json_required '.comfyui.port')
  service_name=$(json_required '.comfyui.service_name')
  log_path=$(json_required '.comfyui.log_path')

  checkout_repository "$app_repo" "$app_ref" "$app_root"
  if [[ ! -x "$app_python" ]]; then
    "$uv_bin" venv "$app_venv" --python "$base_python" --system-site-packages --seed
  fi
  "$uv_bin" pip install --python "$app_python" -r "$app_root/requirements.txt"
else
  app_repo=$(json_required '.webui.repository')
  app_ref=$(json_required '.webui.ref')
  app_root=$(json_required '.webui.root')
  app_venv=$(json_required '.webui.venv')
  app_python=$(json_required '.webui.python')
  app_python_version=$(json_required '.webui.python_version')
  app_host=$(json_required '.webui.listen_host')
  app_port=$(json_required '.webui.port')
  service_name=$(json_required '.webui.service_name')
  log_path=$(json_required '.webui.log_path')

  checkout_repository "$app_repo" "$app_ref" "$app_root"
  export UV_PYTHON_INSTALL_DIR=/workspace/.uv/python
  if [[ ! -x "$app_python" ]]; then
    "$uv_bin" python install "$app_python_version"
    "$uv_bin" venv "$app_venv" --python "$app_python_version" --seed
  fi
  mkdir -p "$app_root/models/Stable-diffusion" "$app_root/models/text_encoder" "$app_root/models/VAE"
  chmod 0755 "$app_root/webui.sh" "$app_root/webui-user.sh" 2>/dev/null || true
fi

stage 'Verifying the selected application Python environment'
if [[ "$application_type" == 'comfyui' ]]; then
  "$app_python" - <<'PY'
import torch
assert torch.cuda.is_available(), 'application torch cannot access CUDA'
print(f'ComfyUI environment: torch={torch.__version__}, cuda={torch.version.cuda}, gpu={torch.cuda.get_device_name(0)}')
PY
else
  echo "Forge Python environment: $($app_python --version)"
  echo 'Forge installs its pinned GPU packages during its first supervised launch.'
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

stage 'Installing application workflow or baseline configuration'
mkdir -p "$project_root/workflows/original"
workflow_name=$(json_required '.anima.workflow_file_name')
if [[ "$application_type" == 'comfyui' ]]; then
  workflow_url=$(json_required '.anima.workflow_url')
  workflow_original="$project_root/workflows/original/$workflow_name"
  download_file "$workflow_url" "$workflow_original" ''
  mkdir -p "$app_root/user/default/workflows"
  cp -n "$workflow_original" "$app_root/user/default/workflows/$workflow_name" || true
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
healthy=false
for attempt in $(seq 1 450); do
  if curl --silent --fail --max-time 5 "$health_url" >/dev/null; then
    healthy=true
    echo "$application_type is healthy: $health_url"
    break
  fi
  if (( attempt % 10 == 0 )); then
    echo "Still waiting for $application_type ($((attempt * 2)) seconds elapsed)..."
    supervisorctl status "$service_name" || true
    tail -n 8 "$log_path" 2>/dev/null || true
  fi
  sleep 2
done
if [[ "$healthy" != true ]]; then
  echo "$application_type did not become healthy at $health_url" >&2
  tail -n 120 "$log_path" 2>/dev/null || true
  exit 9
fi

stage 'Installing Codex CLI and project configuration'
if jq -e '.codex.install == true' "$deploy_config" >/dev/null; then
  bash "$(dirname "$0")/configure-codex.sh" "$deploy_config"
fi

stage 'Running complete deployment verification'
bash "$(dirname "$0")/verify-deployment.sh" "$deploy_config"

echo "PyTorch-based $application_type provisioning complete."
echo "Application root: $app_root"
echo "Application endpoint: $health_url"
echo "Codex project: $project_root"
