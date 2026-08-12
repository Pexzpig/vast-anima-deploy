#!/usr/bin/env bash
set -uo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 /path/to/remote-config.json" >&2
  exit 2
fi

deploy_config=$1
failures=0

ok() {
  printf '[OK] %s\n' "$1"
}

fail() {
  printf '[MISSING] %s\n' "$1" >&2
  failures=$((failures + 1))
}

json_value() {
  jq -er "$1" "$deploy_config" 2>/dev/null || true
}

comfy_root=$(json_value '.comfyui.root')
comfy_ref=$(json_value '.comfyui.ref')
comfy_python=$(json_value '.comfyui.python')
comfy_host=$(json_value '.comfyui.listen_host')
comfy_port=$(json_value '.comfyui.port')
service_name=$(json_value '.comfyui.service_name')
project_root=$(json_value '.codex.project_root')

echo 'Remote deployment verification'
echo "  ComfyUI root: $comfy_root"
echo "  Expected ref: $comfy_ref"
echo "  Health URL: http://${comfy_host}:${comfy_port}/system_stats"

if [[ -d "$comfy_root/.git" ]]; then
  current_commit=$(git -C "$comfy_root" rev-parse HEAD 2>/dev/null || true)
  expected_commit=$(git -C "$comfy_root" rev-parse --verify "${comfy_ref}^{commit}" 2>/dev/null || true)
  if [[ -n "$current_commit" && -n "$expected_commit" && "$current_commit" == "$expected_commit" ]]; then
    ok "ComfyUI checkout $comfy_ref ($current_commit)"
  else
    fail "ComfyUI checkout does not match $comfy_ref (current=${current_commit:-unknown}, expected=${expected_commit:-unknown})"
  fi
else
  fail "ComfyUI Git checkout at $comfy_root"
fi

if [[ -x "$comfy_python" ]] && "$comfy_python" -c 'import torch; assert torch.cuda.is_available()' >/dev/null 2>&1; then
  cuda_summary=$("$comfy_python" -c 'import torch; print(f"torch={torch.__version__}, gpu={torch.cuda.get_device_name(0)}")' 2>/dev/null || true)
  ok "CUDA Python runtime${cuda_summary:+ ($cuda_summary)}"
else
  fail "CUDA-enabled Python runtime at $comfy_python"
fi

while IFS=$'\t' read -r model_name model_folder; do
  model_path="$comfy_root/models/$model_folder/$model_name"
  if [[ -s "$model_path" ]]; then
    model_size=$(du -h "$model_path" 2>/dev/null | awk '{print $1}')
    ok "Model $model_name${model_size:+ ($model_size)}"
  else
    fail "Model $model_path"
  fi
done < <(jq -r '.anima.models[] | [.Name, .Folder] | @tsv' "$deploy_config")

workflow_name=$(json_value '.anima.workflow_file_name')
workflow_original="$project_root/workflows/original/$workflow_name"
if [[ -s "$workflow_original" ]] && jq -e . "$workflow_original" >/dev/null 2>&1; then
  ok "Workflow $workflow_original"
else
  fail "Valid workflow JSON at $workflow_original"
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

health_url="http://${comfy_host}:${comfy_port}/system_stats"
if curl --silent --fail --max-time 5 "$health_url" >/dev/null 2>&1; then
  ok "ComfyUI health endpoint $health_url"
else
  fail "ComfyUI health endpoint $health_url"
fi

if jq -e '.codex.install == true' "$deploy_config" >/dev/null 2>&1; then
  codex_binary=$(command -v codex || true)
  if [[ -z "$codex_binary" && -x /root/.local/bin/codex ]]; then
    codex_binary=/root/.local/bin/codex
  fi
  if [[ -n "$codex_binary" ]]; then
    ok "Codex CLI: $($codex_binary --version 2>/dev/null || echo "$codex_binary")"
  else
    fail 'Codex CLI executable'
  fi
  if [[ -s "$project_root/.codex/config.toml" ]]; then
    ok "Codex project config $project_root/.codex/config.toml"
  else
    fail "Codex project config $project_root/.codex/config.toml"
  fi
  [[ -x /workspace/bin/codex-login.sh ]] && ok 'Codex login helper /workspace/bin/codex-login.sh' || fail 'Codex login helper /workspace/bin/codex-login.sh'
  [[ -x /workspace/bin/run-codex.sh ]] && ok 'Codex runner /workspace/bin/run-codex.sh' || fail 'Codex runner /workspace/bin/run-codex.sh'
fi

if (( failures > 0 )); then
  echo "Remote deployment verification failed: $failures check(s) did not pass." >&2
  exit 20
fi

echo 'Remote deployment verification passed.'
