---
name: transformers
import: transformers
version: 4.x
category: Machine Learning
tags: nlp, llm, tokenizer, pipeline, huggingface
bundled: true
---

# 🤗 Transformers

**Hugging Face's model-hub companion.** Bundled alongside `torch`, `tokenizers`, `huggingface_hub`, and `safetensors`. Use it for on-device text generation, classification, embeddings, and small vision/audio tasks.

## Pipelines (easy mode)

```python
from transformers import pipeline

# The pipeline auto-selects a default model + tokenizer; it will download
# to ~/Documents/huggingface (cached).
clf = pipeline("text-classification")
print(clf("I love this!"))
# [{'label': 'POSITIVE', 'score': 0.9997}]

gen = pipeline("text-generation", model="sshleifer/tiny-gpt2")
print(gen("Once upon a time,", max_new_tokens=30, do_sample=False)[0]["generated_text"])
```

## Manual model + tokenizer

```python
from transformers import AutoTokenizer, AutoModelForCausalLM
import torch

name = "sshleifer/tiny-gpt2"
tok = AutoTokenizer.from_pretrained(name)
model = AutoModelForCausalLM.from_pretrained(name)

dev = "mps" if torch.backends.mps.is_available() else "cpu"
model = model.to(dev).eval()

inputs = tok("Hello, world", return_tensors="pt").to(dev)
with torch.no_grad():
    out = model.generate(**inputs, max_new_tokens=20, do_sample=False)
print(tok.decode(out[0], skip_special_tokens=True))
```

## Embeddings

```python
from transformers import AutoTokenizer, AutoModel
import torch

tok = AutoTokenizer.from_pretrained("sentence-transformers/all-MiniLM-L6-v2")
model = AutoModel.from_pretrained("sentence-transformers/all-MiniLM-L6-v2").eval()

sents = ["The cat sat on the mat.", "A dog ran in the park."]
batch = tok(sents, padding=True, truncation=True, return_tensors="pt")
with torch.no_grad():
    out = model(**batch)

# Mean-pool over tokens, weighted by attention mask
mask = batch["attention_mask"].unsqueeze(-1).float()
emb = (out.last_hidden_state * mask).sum(1) / mask.sum(1)
emb = torch.nn.functional.normalize(emb, dim=-1)
print(emb.shape)  # (2, 384)

# Cosine similarity
sim = (emb[0] @ emb[1]).item()
print(f"similarity = {sim:.3f}")
```

## Vision / image classification

```python
from transformers import AutoImageProcessor, AutoModelForImageClassification
from PIL import Image
import torch

proc = AutoImageProcessor.from_pretrained("google/vit-base-patch16-224")
model = AutoModelForImageClassification.from_pretrained("google/vit-base-patch16-224").eval()

img = Image.open("/tmp/cat.jpg").convert("RGB")
inputs = proc(images=img, return_tensors="pt")
with torch.no_grad():
    logits = model(**inputs).logits
pred = logits.argmax(-1).item()
print(model.config.id2label[pred])
```

## Model caching

By default, models download to `~/.cache/huggingface`. On iOS that's mapped to the app's Caches directory — it'll be purged under memory pressure. To persist:

```python
import os, transformers
os.environ["HF_HOME"] = os.path.expanduser("~/Documents/huggingface")
# Now from_pretrained() caches into Documents/ and survives app restarts.
```

## Useful snippets

### Greedy text generation loop

```python
import torch
@torch.no_grad()
def generate(prompt, max_tokens=50):
    ids = tok(prompt, return_tensors="pt").input_ids.to(dev)
    for _ in range(max_tokens):
        logits = model(ids).logits[:, -1]
        next_id = logits.argmax(-1, keepdim=True)
        ids = torch.cat([ids, next_id], dim=1)
        if next_id.item() == tok.eos_token_id:
            break
    return tok.decode(ids[0], skip_special_tokens=True)
```

### Save memory with half precision

```python
model = AutoModelForCausalLM.from_pretrained(name, torch_dtype=torch.float16).to(dev)
```

## iOS notes

- Only PyTorch checkpoints and safetensors load. TensorFlow / JAX / Flax checkpoints are not supported.
- `bitsandbytes` (8-bit quant) is NOT available — use `torch_dtype=torch.float16` or load a pre-quantised model.
- Downloading a model the first time needs network; after that the cache is offline-usable.
- Use tiny models (`tiny-gpt2`, `distilbert-base-uncased`, `all-MiniLM-L6-v2`) for interactive latency.
