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
    echo "Required command is missing from the Vast base image: $required_command" >&2
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

comfy_repo=$(json_required '.comfyui.repository')
comfy_ref=$(json_required '.comfyui.ref')
comfy_root=$(json_required '.comfyui.root')
comfy_python=$(json_required '.comfyui.python')
comfy_uv=$(json_required '.comfyui.uv')
comfy_host=$(json_required '.comfyui.listen_host')
comfy_port=$(json_required '.comfyui.port')
service_name=$(json_required '.comfyui.service_name')
log_path=$(json_required '.comfyui.log_path')
project_root=$(json_required '.codex.project_root')

if [[ ! -x "$comfy_python" ]]; then
  echo "Configured Python does not exist: $comfy_python" >&2
  exit 6
fi
if [[ ! -x "$comfy_uv" ]]; then
  comfy_uv=$(command -v uv || true)
fi
if [[ -z "$comfy_uv" ]]; then
  echo "uv was not found in the Vast base image." >&2
  exit 6
fi

mkdir -p /workspace/logs /workspace/bin "$project_root/workflows/original" "$project_root/records"

if [[ -d "$comfy_root/.git" ]]; then
  echo "Updating existing ComfyUI checkout without discarding local changes."
  git -C "$comfy_root" fetch --tags origin
  git -C "$comfy_root" checkout "$comfy_ref"
  if git -C "$comfy_root" show-ref --verify --quiet "refs/remotes/origin/$comfy_ref"; then
    git -C "$comfy_root" pull --ff-only origin "$comfy_ref"
  fi
elif [[ -e "$comfy_root" ]]; then
  echo "$comfy_root exists but is not a Git checkout; refusing to overwrite it." >&2
  exit 7
else
  git clone --branch "$comfy_ref" --single-branch "$comfy_repo" "$comfy_root"
fi

if ! "$comfy_python" -c 'import torch; assert torch.cuda.is_available()' >/dev/null 2>&1; then
  echo "Installing a CUDA-aware PyTorch build selected by uv."
  "$comfy_uv" pip install --no-cache --python "$comfy_python" --torch-backend auto torch torchvision torchaudio
fi
"$comfy_uv" pip install --no-cache --python "$comfy_python" -r "$comfy_root/requirements.txt"

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

Keep the original workflow unchanged. Copy it before experiments and change one
prompt group, sampler parameter, or adapter weight at a time. Preserve the
original ComfyUI PNG metadata or workflow JSON for reproducibility.
EOF

start_script=/workspace/bin/start-comfyui.sh
{
  echo '#!/usr/bin/env bash'
  echo 'set -Eeuo pipefail'
  printf 'cd %q\n' "$comfy_root"
  printf 'exec %q main.py --listen %q --port %q' "$comfy_python" "$comfy_host" "$comfy_port"
  while IFS= read -r argument; do
    printf ' %q' "$argument"
  done < <(jq -r '.comfyui.extra_args[]?' "$deploy_config")
  printf '\n'
} > "$start_script"
chmod 0755 "$start_script"

mkdir -p "$(dirname "$log_path")"
supervisor_config="/etc/supervisor/conf.d/${service_name}.conf"
cat > "$supervisor_config" <<EOF
[program:$service_name]
command=$start_script
directory=$comfy_root
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

# Vast SSH launch mode replaces Docker ENTRYPOINT. Normally OnStartCommand
# restores the base-image boot chain; this fallback supports older instances.
if ! supervisorctl pid >/dev/null 2>&1; then
  echo 'Supervisor is not ready; waiting for the image on-start boot chain...'
  for _ in $(seq 1 15); do
    supervisorctl pid >/dev/null 2>&1 && break
    sleep 2
  done
fi
if ! supervisorctl pid >/dev/null 2>&1; then
  if pgrep -x supervisord >/dev/null 2>&1; then
    echo 'A supervisord process exists but its control socket is unavailable.' >&2
    tail -n 100 /var/log/supervisor/supervisord.log 2>/dev/null || true
    exit 9
  fi
  echo 'The image entrypoint was not run by Vast SSH mode; starting Supervisor directly.'
  mkdir -p /var/log/supervisor /var/run
  supervisord -c /etc/supervisor/supervisord.conf
  for _ in $(seq 1 15); do
    supervisorctl pid >/dev/null 2>&1 && break
    sleep 2
  done
fi
if ! supervisorctl pid >/dev/null 2>&1; then
  echo 'Supervisor did not create its control socket.' >&2
  exit 9
fi
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
  echo 'Installed a restart-safe Supervisor fallback in /root/onstart.sh.'
fi

supervisorctl reread
supervisorctl update
supervisorctl restart "$service_name"

health_url="http://127.0.0.1:${comfy_port}/system_stats"
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
  tail -n 100 "$log_path" || true
  exit 9
fi

if jq -e '.codex.install == true' "$deploy_config" >/dev/null; then
  bash "$(dirname "$0")/configure-codex.sh" "$deploy_config"
fi
bash "$(dirname "$0")/verify-deployment.sh" "$deploy_config"

echo "Provisioning complete."
echo "ComfyUI is bound to $comfy_host:$comfy_port and should be accessed through the SSH tunnel."
echo "Original workflow: $workflow_original"
echo "Baseline record: $project_root/records/anima-baseline.json"
