#!/usr/bin/env bash
set -uo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 /path/to/remote-config.json" >&2
  exit 2
fi

deploy_config=$1
failures=0

ok() { printf '[OK] %s\n' "$1"; }
fail() { printf '[MISSING] %s\n' "$1" >&2; failures=$((failures + 1)); }
json_value() { jq -er "$1" "$deploy_config" 2>/dev/null || true; }

application_type=$(json_value '.application.type')
base_python=$(json_value '.pytorch.python')
minimum_cuda=$(json_value '.pytorch.minimum_cuda_version')
project_root=$(json_value '.codex.project_root')
if [[ ! -x "$base_python" ]]; then
  base_python=$(command -v python3 || command -v python || true)
fi

if [[ "$application_type" == 'webui' ]]; then
  app_root=$(json_value '.webui.root')
  app_ref=$(json_value '.webui.commit')
  app_python=$(json_value '.webui.python')
  app_torch_version=$(json_value '.webui.torch_version')
  app_torchvision_version=$(json_value '.webui.torchvision_version')
  app_torch_cuda_version=$(json_value '.webui.torch_cuda_version')
  app_host=$(json_value '.webui.listen_host')
  app_port=$(json_value '.webui.port')
  service_name=$(json_value '.webui.service_name')
  health_url="http://${app_host}:${app_port}/"
  model_folder_key='WebUiFolder'
  application_name='Forge Classic WebUI'
elif [[ "$application_type" == 'comfyui' ]]; then
  app_root=$(json_value '.comfyui.root')
  app_ref=$(json_value '.comfyui.ref')
  app_python=$(json_value '.comfyui.python')
  app_host=$(json_value '.comfyui.listen_host')
  app_port=$(json_value '.comfyui.port')
  service_name=$(json_value '.comfyui.service_name')
  health_url="http://${app_host}:${app_port}/system_stats"
  model_folder_key='ComfyFolder'
  application_name='ComfyUI'
else
  echo "Unsupported application type: ${application_type:-missing}" >&2
  exit 2
fi

echo 'Remote deployment verification'
echo "  Application: $application_name"
echo "  Application root: $app_root"
echo "  Expected ref: $app_ref"
echo "  Health URL: $health_url"

if [[ -x "$base_python" ]] && "$base_python" - "$minimum_cuda" <<'PY' >/tmp/anima-pytorch-check.txt 2>&1
import sys
import torch

minimum = tuple(int(part) for part in sys.argv[1].split('.')[:2])
actual_text = torch.version.cuda or '0.0'
actual = tuple(int(part) for part in actual_text.split('.')[:2])
assert torch.cuda.is_available(), 'torch.cuda.is_available() is false'
assert actual >= minimum, f'CUDA runtime {actual_text} is below required {sys.argv[1]}'
print(f'torch={torch.__version__}, cuda={actual_text}, gpu={torch.cuda.get_device_name(0)}')
PY
then
  pytorch_summary=$(cat /tmp/anima-pytorch-check.txt)
  ok "Base PyTorch environment ($pytorch_summary)"
else
  fail "GPU-enabled PyTorch environment at $base_python (CUDA >= $minimum_cuda)"
  sed 's/^/  /' /tmp/anima-pytorch-check.txt 2>/dev/null || true
fi

if [[ -d "$app_root/.git" ]]; then
  current_commit=$(git -C "$app_root" rev-parse HEAD 2>/dev/null || true)
  expected_commit=$(git -C "$app_root" rev-parse --verify "${app_ref}^{commit}" 2>/dev/null || true)
  if [[ -n "$current_commit" && -n "$expected_commit" && "$current_commit" == "$expected_commit" ]]; then
    ok "$application_name checkout $app_ref ($current_commit)"
  else
    fail "$application_name checkout does not match $app_ref (current=${current_commit:-unknown}, expected=${expected_commit:-unknown})"
  fi
else
  fail "$application_name Git checkout at $app_root"
fi

if [[ "$application_type" == 'webui' ]]; then
  application_python_check=$("$app_python" - "$app_torch_version" "$app_torchvision_version" "$app_torch_cuda_version" <<'PY' 2>&1 || true
import importlib.metadata
import sys
import torch
expected_torch, expected_torchvision, expected_cuda = sys.argv[1:]
assert torch.__version__.split("+", 1)[0] == expected_torch
assert importlib.metadata.version("torchvision").split("+", 1)[0] == expected_torchvision
assert torch.version.cuda == expected_cuda
assert torch.cuda.is_available()
print(f"torch={torch.__version__}, torchvision={importlib.metadata.version('torchvision')}, cuda={torch.version.cuda}, gpu={torch.cuda.get_device_name(0)}")
PY
  )
  if [[ "$application_python_check" == torch=* ]]; then
    ok "$application_name Python environment ($application_python_check)"
  else
    fail "Pinned CUDA-enabled $application_name Python environment at $app_python"
    [[ -z "$application_python_check" ]] || printf '  %s\n' "$application_python_check" >&2
  fi
elif [[ -x "$app_python" ]] && "$app_python" -c 'import torch; assert torch.cuda.is_available()' >/dev/null 2>&1; then
  cuda_summary=$("$app_python" -c 'import torch; print(f"torch={torch.__version__}, cuda={torch.version.cuda}, gpu={torch.cuda.get_device_name(0)}")' 2>/dev/null || true)
  ok "$application_name Python environment${cuda_summary:+ ($cuda_summary)}"
else
  fail "CUDA-enabled $application_name Python environment at $app_python"
fi

while IFS=$'\t' read -r model_name model_folder model_sha; do
  model_path="$app_root/models/$model_folder/$model_name"
  if [[ ! -s "$model_path" ]]; then
    fail "Model $model_path"
  elif [[ -n "$model_sha" ]] && ! echo "$model_sha  $model_path" | sha256sum --check --status; then
    fail "Model checksum $model_path"
  else
    model_size=$(du -h "$model_path" 2>/dev/null | awk '{print $1}')
    ok "Model $model_name${model_size:+ ($model_size)}"
  fi
done < <(jq -r --arg folder "$model_folder_key" '.anima.models[] | [.Name, .[$folder], (.Sha256 // "")] | @tsv' "$deploy_config")

if [[ "$application_type" == 'comfyui' ]]; then
  workflow_name=$(json_value '.anima.workflow_file_name')
  managed_workflow_name=$(json_value '.anima.managed_workflow_file_name')
  workflow_sha=$(json_value '.anima.workflow_sha256')
  workflow_original="$project_root/workflows/original/$workflow_name"
  workflow_managed="$project_root/workflows/$managed_workflow_name"
  workflow_installed="$app_root/user/default/workflows/$managed_workflow_name"
  if [[ -s "$workflow_original" ]] &&
    echo "$workflow_sha  $workflow_original" | sha256sum --check --status &&
    "$base_python" "$(dirname "$0")/configure-application.py" verify-workflow \
      "$deploy_config" "$workflow_original" "$workflow_managed" "$workflow_installed"; then
    ok "Pinned and configured workflow $workflow_installed"
  else
    fail "Pinned original and configured Anima workflow"
  fi
else
  webui_config="$app_root/config.json"
  localization=$(json_value '.webui.localization')
  if [[ -s "$webui_config" ]] &&
    jq -e --arg localization "$localization" \
      '.localization == $localization and .disable_all_extensions == "none" and (.VERSION_UID | type == "string" and length > 0)' \
      "$webui_config" >/dev/null 2>&1; then
    ok "WebUI localization $localization is enabled in a versioned config"
  else
    fail "WebUI localization $localization and Forge VERSION_UID in $webui_config"
  fi

  while IFS=$'\t' read -r extension_name extension_commit; do
    extension_root="$app_root/extensions/$extension_name"
    actual_commit=$(git -C "$extension_root" rev-parse HEAD 2>/dev/null || true)
    if [[ "$actual_commit" == "$extension_commit" ]] &&
      ! jq -e --arg name "$extension_name" '(.disabled_extensions // []) | index($name)' "$webui_config" >/dev/null 2>&1; then
      ok "WebUI extension $extension_name ($extension_commit)"
    else
      fail "Enabled WebUI extension $extension_name at commit $extension_commit"
    fi
  done < <(jq -r '.webui.extensions[] | select(.Enabled == true) | [.Name, .Commit] | @tsv' "$deploy_config")
fi

if [[ -s "$project_root/records/anima-baseline.json" ]]; then
  ok "Baseline record $project_root/records/anima-baseline.json"
else
  fail "Baseline record $project_root/records/anima-baseline.json"
fi

supervisor_status=$(supervisorctl status "$service_name" 2>&1 || true)
if [[ "$supervisor_status" == *RUNNING* ]]; then
  ok "Supervisor service: $supervisor_status"
else
  fail "Supervisor service $service_name: $supervisor_status"
fi

if curl --silent --fail --max-time 5 "$health_url" >/dev/null 2>&1; then
  ok "$application_name health endpoint $health_url"
else
  fail "$application_name health endpoint $health_url"
fi

if jq -e '.codex.install == true' "$deploy_config" >/dev/null 2>&1; then
  codex_binary=$(command -v codex || true)
  [[ -n "$codex_binary" ]] || [[ ! -x /root/.local/bin/codex ]] || codex_binary=/root/.local/bin/codex
  if [[ -n "$codex_binary" ]]; then
    ok "Codex CLI: $($codex_binary --version 2>/dev/null || echo "$codex_binary")"
  else
    fail 'Codex CLI executable'
  fi
  [[ -s "$project_root/.codex/config.toml" ]] && ok "Codex project config $project_root/.codex/config.toml" || fail "Codex project config $project_root/.codex/config.toml"
  [[ -x /workspace/bin/codex-login.sh ]] && ok 'Codex login helper /workspace/bin/codex-login.sh' || fail 'Codex login helper /workspace/bin/codex-login.sh'
  [[ -x /workspace/bin/run-codex.sh ]] && ok 'Codex runner /workspace/bin/run-codex.sh' || fail 'Codex runner /workspace/bin/run-codex.sh'
fi

if (( failures > 0 )); then
  echo "Remote deployment verification failed: $failures check(s) did not pass." >&2
  exit 20
fi

echo 'Remote deployment verification passed.'
