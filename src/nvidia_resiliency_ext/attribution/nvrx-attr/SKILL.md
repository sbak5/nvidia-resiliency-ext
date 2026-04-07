---
name: nvrx-attr
description: >
  Orchestration layer over nvidia_resiliency_ext attribution modules. Provides two sub-skills:
  log-analysis (analyze SLURM job logs for failure root-cause and restart decisions) and
  fr-analysis (analyze NCCL flight-recorder dumps to identify collective hangs and isolate
  responsible ranks). Use when diagnosing why a distributed training job failed.
compatibility: Requires Python 3.8+, nvidia-resiliency-ext installed, langchain-nvidia-ai-endpoints, and NVIDIA_API_KEY (env var, NVIDIA_API_KEY_FILE, or ~/.nvidia_api_key).
metadata:
  author: nvidia
---

# Attribution Skills

High-level orchestration layer over the `nvidia_resiliency_ext.attribution` modules.
Each subdirectory is a self-contained skill with its own `SKILL.md` and a `scripts/` folder
that symlinks to the canonical source under `attribution/`.

## Skills

| Directory | Purpose | Entry point |
|-----------|---------|------------|
| [`log-analysis/`](./log-analysis/SKILL.md) | Analyze SLURM job logs for failure root-cause and restart decisions | `NVRxLogAnalyzer` (`nvrx_logsage.py`) |
| [`fr-analysis/`](./fr-analysis/SKILL.md) | Analyze NCCL flight-recorder dumps for collective-hang root-cause | `CollectiveAnalyzer` (`fr_attribution.py`) |

## How skills relate to the library

```
attribution/
├── log_analyzer/nvrx_logsage.py      ← log_analysis skill source
├── trace_analyzer/fr_attribution.py  ← fr_analysis skill source
├── analyzer/engine.py                ← Analyzer: coalesces both via RequestCoalescer
├── combined_log_fr/                  ← optional LLM fusion of log + FR results
└── nvrx-attr/                        ← this directory
    ├── log-analysis/
    └── fr-analysis/
```

The `Analyzer` (`analyzer/engine.py`) is the recommended entry point when you need
request coalescing, result caching, or the combined `LOG_AND_TRACE` pipeline.
Use the individual skills when you want to run one analysis type directly without the
full coalescing stack.

## Common prerequisites

- `NVIDIA_API_KEY` environment variable, `NVIDIA_API_KEY_FILE`, or `~/.nvidia_api_key`
- `langchain-nvidia-ai-endpoints` installed (`pip install langchain-nvidia-ai-endpoints`)
- `logsage` package installed (required by `log_analysis`)
- Package installed: `pip install nvidia-resiliency-ext` or `pip install -e .` from repo root
