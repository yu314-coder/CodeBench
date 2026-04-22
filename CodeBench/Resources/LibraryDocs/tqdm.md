---
name: tqdm
import: tqdm
version: 4.x
category: Utilities
tags: progress, bar, loop
bundled: true
---

# tqdm

**Fast, extensible progress bars** that work in the editor's output pane.

## Wrap any iterable

```python
from tqdm import tqdm
import time

for i in tqdm(range(100), desc="Crunching"):
    time.sleep(0.01)
```

Output looks like:

```
Crunching: 100%|██████████| 100/100 [00:01<00:00, 92.4it/s]
```

## With a known total

```python
total = 256
with tqdm(total=total, unit="MB") as pbar:
    for i in range(total):
        # ... do work ...
        pbar.update(1)
```

## Nested bars

```python
for epoch in tqdm(range(5), desc="Epochs"):
    for batch in tqdm(range(100), desc="Batches", leave=False):
        time.sleep(0.003)
```

## Integration with pandas

```python
import pandas as pd
from tqdm import tqdm
tqdm.pandas()

df = pd.DataFrame({"x": range(10_000)})
df["y"] = df["x"].progress_apply(lambda v: v ** 2)
```

## Manual update + set_postfix

```python
pbar = tqdm(range(1000), desc="Train")
for step in pbar:
    loss = 1.0 / (1 + step / 10)
    pbar.set_postfix(loss=f"{loss:.3f}", lr="1e-3")
```

## tqdm.asyncio

```python
from tqdm.asyncio import tqdm as atqdm
import asyncio

async def work(n):
    await asyncio.sleep(0.01)
    return n * n

async def main():
    results = []
    for coro in atqdm(asyncio.as_completed([work(i) for i in range(100)]),
                      total=100, desc="async"):
        results.append(await coro)

asyncio.run(main())
```

## iOS notes

- tqdm writes to **stderr** by default; both stderr and stdout stream to the editor's output pane.
- In non-TTY mode (the default inside our sandbox), tqdm refreshes the single progress line every few hundred ms — looks clean.
- For fancy colored bars that also draw tables and panels, see **rich.progress** (`rich.md`).
