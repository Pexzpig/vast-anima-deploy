@{
    Secrets = @{
        VastApiKeyEnvironmentVariable = 'VAST_API_KEY'
        OpenAIApiKeyEnvironmentVariable = 'OPENAI_API_KEY'
        HuggingFaceTokenEnvironmentVariable = 'HF_TOKEN'
    }

    Vast = @{
        Cli = 'vastai'
        Search = @{
            Query = 'gpu_name in [RTX_3090,RTX_3090_Ti,RTX_4080,RTX_4080S,RTX_4090,RTX_4090D,RTX_5080,RTX_5090,RTX_4000Ada,RTX_4500Ada,RTX_5000Ada,RTX_5880Ada,RTX_6000Ada,RTX_PRO_4000,RTX_PRO_4500,RTX_PRO_5000,RTX_PRO_6000_S,RTX_PRO_6000_WS,RTX_A4000,RTX_A4500,RTX_A5000,RTX_A6000,A10,A10g,A40,L4,L40,L40S,A100_PCIE,A100_SXM4,A100X,A800_PCIE,H100_PCIE,H100_SXM,H100_NVL,H200,H200_NVL,B200] num_gpus=1 gpu_ram>=16 verified=true rentable=true rented=false direct_port_count>=1 reliability>0.98 inet_down>200 cuda_vers>=12.8 dph_total<=0.80'
            Order = 'dph_total'
            Limit = 25
            MaxHourlyUsd = 0.80
            LastSearchPath = 'state/last-search.json'
        }
        Instance = @{
            Label = 'anima-pytorch-ui'
            # CUDA 12.8 retains compatibility with the configured marketplace
            # filter while providing a current, GPU-enabled PyTorch runtime.
            Image = 'vastai/pytorch:cuda-12.8.1-auto'
            OnStartCommand = '/opt/instance-tools/bin/entrypoint.sh'
            ContainerDiskGb = 60
            DirectSsh = $true
            WaitTimeoutSeconds = 900
            PollIntervalSeconds = 15
            Environment = @{
                TZ = 'Asia/Shanghai'
                ENABLE_AUTH = 'true'
                ENABLE_HTTPS = 'true'
            }
        }
        Volume = @{
            Enabled = $true
            SizeGb = 80
            LabelPrefix = 'anima_pytorch_ui'
            MountPath = '/workspace'
            SearchQueryTemplate = 'machine_id={machine_id} disk_space>={size_gb} verified=true reliability>0.98'
            SearchOrder = 'storage_cost'
            SearchLimit = 10
        }
        Ssh = @{
            User = 'root'
            IdentityFile = ''
            StrictHostKeyChecking = 'accept-new'
            ConnectTimeoutSeconds = 15
        }
    }

    PyTorch = @{
        Python = '/venv/main/bin/python'
        MinimumCudaVersion = '12.8'
    }

    Application = @{
        # Used as the default selection shown before each new deployment.
        DefaultType = 'comfyui'
    }

    ComfyUI = @{
        Repository = 'https://github.com/Comfy-Org/ComfyUI.git'
        Ref = 'v0.28.0'
        Root = '/workspace/ComfyUI'
        Venv = '/workspace/venvs/comfyui'
        Python = '/workspace/venvs/comfyui/bin/python'
        ListenHost = '127.0.0.1'
        Port = 18188
        LocalPort = 28188
        ServiceName = 'comfyui'
        LogPath = '/workspace/logs/comfyui.log'
        ExtraArgs = @('--disable-auto-launch', '--enable-cors-header')
    }

    WebUI = @{
        Repository = 'https://github.com/Haoming02/sd-webui-forge-classic.git'
        Ref = 'neo'
        Root = '/workspace/sd-webui-forge-classic'
        Venv = '/workspace/venvs/webui'
        Python = '/workspace/venvs/webui/bin/python'
        PythonVersion = '3.13'
        ListenHost = '127.0.0.1'
        Port = 17860
        LocalPort = 27860
        ServiceName = 'webui'
        LogPath = '/workspace/logs/webui.log'
        ModelRoot = '/workspace/sd-webui-forge-classic/models'
        ExtraArgs = @('--api', '--uv', '--skip-version-check')
    }

    System = @{
        Packages = @('git', 'ffmpeg', 'libgl1', 'libglib2.0-0', 'wget', 'curl', 'aria2', 'tmux', 'jq', 'procps', 'supervisor')
    }

    Anima = @{
        Variant = 'base-v1.0'
        WorkflowUrl = 'https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/image_anima_base_v1.json'
        WorkflowFileName = 'image_anima_base_v1.json'
        Models = @(
            @{
                Name = 'anima-base-v1.0.safetensors'
                ComfyFolder = 'diffusion_models'
                WebUiFolder = 'Stable-diffusion'
                Url = 'https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/diffusion_models/anima-base-v1.0.safetensors'
                Sha256 = 'bd43b7cffe1ed1153d9c41e7beb2f18cb1273eafbaa3af3edd6a173dc90a006e'
            },
            @{
                Name = 'qwen_3_06b_base.safetensors'
                ComfyFolder = 'text_encoders'
                WebUiFolder = 'text_encoder'
                Url = 'https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/text_encoders/qwen_3_06b_base.safetensors'
                Sha256 = 'cd2a512003e2f9f3cd3c32a9c3573f820bb28c940f73c57b1ddaa983d9223eba'
            },
            @{
                Name = 'qwen_image_vae.safetensors'
                ComfyFolder = 'vae'
                WebUiFolder = 'VAE'
                Url = 'https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/vae/qwen_image_vae.safetensors'
                Sha256 = 'a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f'
            }
        )
        Baseline = @{
            Width = 1024
            Height = 1024
            Steps = 35
            Cfg = 4.5
            Sampler = 'er_sde'
            Scheduler = 'simple'
            Seed = 20260806
            PositivePrompt = 'masterpiece, best quality, score_7, safe, 1girl, solo, smile, looking at viewer, upper body, simple background, soft lighting'
            NegativePrompt = 'worst quality, low quality, blurry, bad anatomy, bad hands, extra fingers, missing fingers, text, watermark, signature, logo'
        }
    }

    Codex = @{
        Install = $true
        InstallerUrl = 'https://chatgpt.com/codex/install.sh'
        ProjectRoot = '/workspace/anima-project'
        AuthMode = 'device'
        ApiKeyEnvironmentVariable = 'OPENAI_API_KEY'
        ApprovalPolicy = 'on-request'
        SandboxMode = 'workspace-write'
        Model = ''
    }

    Local = @{
        StatePath = 'state/deployment.json'
        GeneratedRemoteConfigPath = 'state/remote-config.json'
        RemoteUploadDirectory = '/tmp/anima-vast-deploy'
        ProvisionScriptPath = 'remote/provision.sh'
        CodexScriptPath = 'remote/configure-codex.sh'
    }
}
