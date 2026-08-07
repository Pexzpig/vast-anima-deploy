@{
    # Secrets are never stored in this file. Initialize-Vast.ps1 reads this
    # environment variable and writes the key to Vast CLI's user config.
    Secrets = @{
        VastApiKeyEnvironmentVariable = 'VAST_API_KEY'
        # Optional: only used if you later choose Codex API-key login manually.
        # The deployment scripts never upload this secret to Vast.
        OpenAIApiKeyEnvironmentVariable = 'OPENAI_API_KEY'
        # Current Anima files are public, so this is normally unnecessary.
        HuggingFaceTokenEnvironmentVariable = 'HF_TOKEN'
    }

    Vast = @{
        Cli = 'vastai'

        # Every deployment re-runs this stored scope. Vast query syntax uses
        # underscores in GPU names and '-' after an order field for descending.
        Search = @{
            Query = 'gpu_name in [RTX_4090,RTX_3090,RTX_A5000,A40,L40S] num_gpus=1 gpu_ram>=16 verified=true rentable=true rented=false direct_port_count>=1 reliability>0.98 inet_down>200 cuda_vers>=12.8 dph_total<=0.80'
            Order = 'dph_total'
            Limit = 25
            MaxHourlyUsd = 0.80
            LastSearchPath = 'state/last-search.json'
        }

        Instance = @{
            Label = 'anima-comfyui-example'
            Image = 'vastai/base-image:cuda-12.8.1-cudnn-devel-ubuntu22.04-py310'
            ContainerDiskGb = 30
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
            LabelPrefix = 'anima_comfyui'
            MountPath = '/workspace'

            # {machine_id} and {size_gb} are replaced after a GPU offer is
            # selected. This keeps the volume on the same physical machine.
            SearchQueryTemplate = 'machine_id={machine_id} disk_space>={size_gb} verified=true reliability>0.98'
            SearchOrder = 'storage_cost'
            SearchLimit = 10
        }

        Ssh = @{
            User = 'root'
            IdentityFile = ''
            StrictHostKeyChecking = 'accept-new'
            ConnectTimeoutSeconds = 15
            LocalComfyPort = 18188
        }
    }

    ComfyUI = @{
        Repository = 'https://github.com/comfyanonymous/ComfyUI.git'
        Ref = 'master'
        Root = '/workspace/ComfyUI'
        Python = '/venv/main/bin/python'
        Uv = '/venv/main/bin/uv'
        ListenHost = '127.0.0.1'
        Port = 18188
        ServiceName = 'comfyui'
        LogPath = '/workspace/logs/comfyui.log'
        ExtraArgs = @()
    }

    Anima = @{
        Variant = 'base-v1.0'
        WorkflowUrl = 'https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/image_anima_base_v1.json'
        WorkflowFileName = 'image_anima_base_v1.json'
        Models = @(
            @{
                Name = 'anima-base-v1.0.safetensors'
                Folder = 'diffusion_models'
                Url = 'https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/diffusion_models/anima-base-v1.0.safetensors'
                Sha256 = ''
            },
            @{
                Name = 'qwen_3_06b_base.safetensors'
                Folder = 'text_encoders'
                Url = 'https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/text_encoders/qwen_3_06b_base.safetensors'
                Sha256 = ''
            },
            @{
                Name = 'qwen_image_vae.safetensors'
                Folder = 'vae'
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
        # Empty means use the current Codex default/model picker rather than
        # pinning a model name that can become stale.
        Model = ''
    }

    Local = @{
        StatePath = 'state/deployment.json'
        GeneratedRemoteConfigPath = 'state/remote-config.json'
        RemoteUploadDirectory = '/tmp/anima-vast-deploy'
    }
}
