[CmdletBinding()]
param([string]$ConfigPath)

# Backward-compatible entry point. The selected deployment may be ComfyUI or
# Forge WebUI, so all new code uses the generic application tunnel.
& (Join-Path $PSScriptRoot 'Open-AppTunnel.ps1') -ConfigPath $ConfigPath
