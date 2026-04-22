---
name: huggingface_hub
import: huggingface_hub
version: 0.24.7
category: Machine Learning
tags: download, model, dataset, hub, repo, hf, inference
bundled: true
---

# huggingface_hub

**The official client for the Hugging Face Hub.** Bundled at version 0.24.7 so it stays compatible with the shipped `transformers` 4.41.2 (which pins `huggingface-hub < 1.0, >= 0.23.0`).

Use it to download any model / dataset / space, search the Hub, read/write your own repos, manage the local cache, and call the Inference API. The whole library is Python — no extensions — so it works unchanged on iOS once you export the env vars below.

## Setup — always do this first on iOS

iOS app caches get purged under memory pressure. Point the HF cache at `~/Documents/huggingface` so your downloaded models survive restarts:

```python
import os
os.environ["HF_HOME"]            = os.path.expanduser("~/Documents/huggingface")
os.environ["HF_HUB_CACHE"]       = os.path.expanduser("~/Documents/huggingface/hub")
os.environ["TRANSFORMERS_CACHE"] = os.path.expanduser("~/Documents/huggingface/hub")  # legacy name
# Optional: keep HF offline if you've already downloaded everything
# os.environ["HF_HUB_OFFLINE"]   = "1"
```

The very first `hf_hub_download` / `AutoModel.from_pretrained` call goes over the network; every subsequent call is offline.

## Authentication

Public repos work anonymously. Private repos and higher rate limits need a token.

```python
from huggingface_hub import login, logout, whoami, HfFolder

login(token="hf_YourTokenHere")       # saves to HfFolder.path_token
# or programmatic:
HfFolder.save_token("hf_YourTokenHere")

print(whoami())                       # {'name': 'you', 'type': 'user', ...}
logout()                              # clears the stored token
```

You can also just set `HF_TOKEN` env var — all the APIs below auto-pick it up.

## Download a single file

```python
from huggingface_hub import hf_hub_download

path = hf_hub_download(
    repo_id="sshleifer/tiny-gpt2",
    filename="config.json",
    cache_dir=os.path.expanduser("~/Documents/huggingface/hub"),
    revision="main",              # branch, tag, or commit sha
)
print(path)                       # local file path
```

The returned path is under your cache and safe to open with `open(path)`.

```python
# Token-gated model:
path = hf_hub_download("meta-llama/Llama-2-7b", "config.json", token="hf_…")

# Pick a specific revision:
hf_hub_download("bert-base-uncased", "pytorch_model.bin", revision="v1.0")
```

## Snapshot an entire repo

```python
from huggingface_hub import snapshot_download

local = snapshot_download(
    repo_id="sentence-transformers/all-MiniLM-L6-v2",
    cache_dir=os.path.expanduser("~/Documents/huggingface/hub"),
    # Cuts download size by skipping what you don't use:
    allow_patterns=["*.json", "*.txt", "*.bin", "tokenizer*", "sentencepiece*"],
    ignore_patterns=["*.msgpack", "*.onnx", "*.h5"],      # skip TF/ONNX/flax
)
print(local)                                             # path to the snapshot dir
```

Advanced options:

```python
snapshot_download(
    "repo/id",
    local_dir="/my/own/path",                 # force output location
    local_dir_use_symlinks="auto",            # True/False/"auto" — iOS defaults "auto"
    resume_download=True,                     # continue interrupted downloads
    force_download=False,                     # redownload even if cached
    max_workers=4,                            # parallelism
    tqdm_class=None,                          # pass rich.progress.tqdm for nicer bar
)
```

## Searching the Hub

```python
from huggingface_hub import HfApi
api = HfApi()

# Most-downloaded small text-generation models:
for m in api.list_models(
        task="text-generation",
        sort="downloads",
        direction=-1,
        limit=10,
        library="pytorch"):
    print(f"{m.id:50}  ↓{m.downloads:>10}  ⭐{m.likes}")

# Filter by model type and license:
api.list_models(
    filter=["bert", "license:apache-2.0", "pytorch"],
    full=True,                                # include siblings metadata
    sort="lastModified", direction=-1,
    limit=5,
)

# Datasets
for d in api.list_datasets(author="allenai", sort="downloads", direction=-1, limit=5):
    print(d.id, d.tags)

# Spaces (demo apps)
api.list_spaces(search="stable-diffusion", limit=3)
```

## Deep inspect a repo (before downloading)

```python
info = api.model_info("bert-base-uncased")
print(info.id, info.sha, info.pipeline_tag, info.tags)
for f in info.siblings:
    print(f"  {f.rfilename:30}  {f.size or '?':>10}")

# Just the file list
files = api.list_repo_files("bert-base-uncased")
print(len(files), "files")

# File URL (without downloading)
from huggingface_hub import hf_hub_url
print(hf_hub_url("bert-base-uncased", "config.json"))
```

## Repo management (write)

```python
# Create a new repo
api.create_repo(repo_id="you/my-model", private=True, repo_type="model")

# Upload a single file
api.upload_file(
    path_or_fileobj="/tmp/my_model.bin",
    path_in_repo="pytorch_model.bin",
    repo_id="you/my-model",
    commit_message="add weights",
)

# Upload a whole folder
api.upload_folder(
    folder_path="/tmp/my_trained_model",
    repo_id="you/my-model",
    commit_message="v1 release",
    ignore_patterns=["*.pt", ".DS_Store"],
    delete_patterns=["old_*"],       # delete these from the remote
)

# Delete
api.delete_repo("you/my-model")
```

## Cache management (inspect + prune)

```python
from huggingface_hub import scan_cache_dir, DeleteStrategy

cache = scan_cache_dir()
print(f"Total on disk: {cache.size_on_disk_str}")

# Sorted biggest-first:
for repo in sorted(cache.repos, key=lambda r: -r.size_on_disk):
    print(f"  {repo.repo_id:50}  {repo.size_on_disk_str:>10}  "
          f"({repo.nb_files} files, {repo.last_accessed_str})")

# Prune all revisions not used in the last 30 days:
strategy = cache.delete_revisions(
    *[rev.commit_hash
      for repo in cache.repos
      for rev in repo.revisions
      if (time.time() - rev.last_modified) > 30*86400]
)
print(f"Will free: {strategy.expected_freed_size_str}")
strategy.execute()
```

Or the CLI-style one-shot:
```python
from huggingface_hub import delete_repo_from_cache
delete_repo_from_cache("stabilityai/stable-diffusion-xl-base-1.0")
```

## Inference API — run models you haven't downloaded

```python
from huggingface_hub import InferenceClient

client = InferenceClient()            # uses HF_TOKEN env var

# Text generation
print(client.text_generation("The capital of France is",
                             model="mistralai/Mistral-7B-Instruct-v0.2",
                             max_new_tokens=20))

# Chat API (OpenAI-compatible)
resp = client.chat_completion(
    messages=[{"role": "user", "content": "Explain MPS backend briefly."}],
    model="meta-llama/Llama-3.1-8B-Instruct",
    max_tokens=200,
)
print(resp.choices[0].message.content)

# Image generation
img_bytes = client.text_to_image("A sphinx cat in space", model="stabilityai/stable-diffusion-3")
with open("/tmp/cat.png", "wb") as f: f.write(img_bytes)

# Speech-to-text, NER, classification, summarization, embeddings — all
# have matching client methods; see InferenceClient.__dir__()
```

Token required (free tier is 30k chars/day). Great fit on iOS because the compute runs on HF's servers, not on-device.

## Low-level HTTP helpers

When you need to fetch something the library doesn't wrap:

```python
from huggingface_hub import hf_hub_url, get_hf_file_metadata
import requests

meta = get_hf_file_metadata(url=hf_hub_url("bert-base-uncased", "config.json"))
print(meta.commit_hash, meta.size, meta.etag, meta.location)

# Raw download
r = requests.get(meta.location, stream=True, timeout=60)
```

## Common module map

| Module | What's in it |
|---|---|
| `huggingface_hub` | Top-level: `hf_hub_download`, `snapshot_download`, `login`, `whoami`, `HfApi`, `InferenceClient` |
| `huggingface_hub.hf_api` | `HfApi` class — every API endpoint |
| `huggingface_hub.file_download` | `hf_hub_download`, `cached_download`, `hf_hub_url` |
| `huggingface_hub.utils` | `build_hf_headers`, `http_backoff`, `HfHubHTTPError`, filters |
| `huggingface_hub.repocard` | Parse / generate README.md model cards |
| `huggingface_hub.constants` | `HF_HOME`, `HF_HUB_CACHE`, `REPO_TYPES`, etc. |
| `huggingface_hub.serialization` | Save/load safetensors split by shard |
| `huggingface_hub.inference` | `InferenceClient` + `AsyncInferenceClient` |

## iOS notes

- Always set `HF_HOME` to `~/Documents/…` before any HF call — the default cache is in `~/Library/Caches/` which iOS may purge.
- The first download over ~200 MB may be interrupted by iOS foreground restrictions if the app backgrounds; `resume_download=True` (the default) picks up where it left off.
- `snapshot_download(allow_patterns=[…])` is crucial for big repos — a full SD-XL snapshot is 18 GB but the 100 MB you actually need is often just `*.json` + one `*.safetensors`.
- Use the **Inference API** (`InferenceClient`) for anything bigger than a tiny GPT-2 — running a 7B model on iOS needs 4-bit quant and careful memory management; letting HF host it is trivially faster.
- All public repos work without a token. Set `HF_TOKEN` or call `login()` once for private access.
