#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 /path/to/remote-config.json" >&2
  exit 2
fi

deploy_config=$1
project_root=$(jq -er '.codex.project_root' "$deploy_config")
installer_url=$(jq -er '.codex.installer_url' "$deploy_config")
approval_policy=$(jq -er '.codex.approval_policy' "$deploy_config")
sandbox_mode=$(jq -er '.codex.sandbox_mode' "$deploy_config")
model=$(jq -r '.codex.model // ""' "$deploy_config")
auth_mode=$(jq -er '.codex.auth_mode' "$deploy_config")
api_key_env=$(jq -er '.codex.api_key_environment_variable' "$deploy_config")

case "$approval_policy" in
  untrusted|on-request|never) ;;
  *) echo "Unsupported Codex approval policy: $approval_policy" >&2; exit 11 ;;
esac
case "$sandbox_mode" in
  read-only|workspace-write|danger-full-access) ;;
  *) echo "Unsupported Codex sandbox mode: $sandbox_mode" >&2; exit 11 ;;
esac

if ! command -v codex >/dev/null 2>&1; then
  echo "[codex 1/4] Installing Codex CLI from the configured official installer URL."
  curl --fail --silent --show-error --location "$installer_url" | sh
else
  echo "[codex 1/4] Existing Codex CLI found; installation skipped."
fi

codex_binary=$(command -v codex || true)
if [[ -z "$codex_binary" && -x /root/.local/bin/codex ]]; then
  codex_binary=/root/.local/bin/codex
fi
if [[ -z "$codex_binary" ]]; then
  echo "Codex installer completed but the codex binary was not found." >&2
  exit 10
fi

echo "[codex 2/4] Writing project configuration and workspace rules."
mkdir -p "$project_root/.codex" /workspace/bin
codex_config="$project_root/.codex/config.toml"
if [[ -e "$codex_config" ]]; then
  cp "$codex_config" "${codex_config}.before-anima-deploy.$(date -u +%Y%m%dT%H%M%SZ)"
fi
{
  printf 'approval_policy = "%s"\n' "$approval_policy"
  printf 'sandbox_mode = "%s"\n' "$sandbox_mode"
  if [[ -n "$model" ]]; then
    if [[ ! "$model" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "Unsafe model value in configuration: $model" >&2
      exit 11
    fi
    printf 'model = "%s"\n' "$model"
  fi
} > "$codex_config"

if [[ ! -e "$project_root/AGENTS.md" ]]; then
  cat > "$project_root/AGENTS.md" <<'EOF'
# Anima / ComfyUI workspace rules

- Preserve files under `workflows/original/`; make experimental copies.
- Do not delete or replace model files unless the user explicitly requests it.
- Keep ComfyUI bound to localhost and use the SSH tunnel for access.
- Record model filename, workflow, seed, size, sampler, scheduler, steps, and CFG.
- Validate workflow JSON before submitting it to the local ComfyUI API.
- Do not print, commit, or copy authentication tokens into this workspace.
EOF
fi

login_script=/workspace/bin/codex-login.sh
echo "[codex 3/4] Creating login and launcher helpers."
if [[ "$auth_mode" == 'device' ]]; then
  cat > "$login_script" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd $(printf '%q' "$project_root")
exec $(printf '%q' "$codex_binary") login --device-auth
EOF
elif [[ "$auth_mode" == 'api-key' ]]; then
  if [[ ! "$api_key_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "Unsafe API key environment variable name: $api_key_env" >&2
    exit 11
  fi
  cat > "$login_script" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd $(printf '%q' "$project_root")
if [[ -z "\${$api_key_env:-}" ]]; then
  echo 'Set $api_key_env in this shell first.' >&2
  exit 2
fi
printf '%s' "\${$api_key_env}" | $(printf '%q' "$codex_binary") login --with-api-key
EOF
else
  echo "Unsupported Codex auth mode: $auth_mode" >&2
  exit 11
fi
chmod 0755 "$login_script"

cat > /workspace/bin/run-codex.sh <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd $(printf '%q' "$project_root")
exec $(printf '%q' "$codex_binary") "\$@"
EOF
chmod 0755 /workspace/bin/run-codex.sh

echo "[codex 4/4] Verifying the Codex CLI installation."
echo "Codex CLI: $($codex_binary --version)"
echo "Project config: $codex_config"
if [[ "$auth_mode" == 'device' ]]; then
  echo "Authentication is intentionally not automated. Run /workspace/bin/codex-login.sh over SSH."
else
  echo "Set $api_key_env only in the interactive SSH shell, then run /workspace/bin/codex-login.sh."
fi
