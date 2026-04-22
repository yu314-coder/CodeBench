---
name: numpy
import: numpy
version: 2.1.x
category: Numerical Computing
tags: array, matrix, linalg, fft, random
bundled: true
---

# NumPy

**The bedrock of the Python scientific stack.** Cross-compiled for iOS arm64 with full OpenBLAS support, so linear-algebra-heavy workloads run at native speed.

## Quick start

```python
import numpy as np

a = np.arange(12).reshape(3, 4)
print(a)
# [[ 0  1  2  3]
#  [ 4  5  6  7]
#  [ 8  9 10 11]]

print(a.sum(axis=0))     # column sums
print(a @ a.T)           # matrix multiplication
print(np.linalg.det(np.eye(3) * 2))  # determinant
```

## Array creation

```python
np.zeros((3, 3))
np.ones(5, dtype=np.float32)
np.eye(4)                         # identity
np.full((2, 2), 7)
np.linspace(0, 1, 11)
np.arange(0, 10, 0.5)
np.random.default_rng(42).normal(size=(1000,))
```

## Slicing & indexing

```python
a = np.arange(24).reshape(4, 6)
a[1]          # row 1
a[:, 2]       # column 2
a[1:3, 2:5]   # sub-block
a[a > 10]     # boolean mask
a[[0, 2], :]  # fancy indexing
```

## Linear algebra (backed by OpenBLAS)

```python
A = np.random.default_rng(0).normal(size=(4, 4))
np.linalg.inv(A)
np.linalg.eig(A)
np.linalg.svd(A, full_matrices=False)
np.linalg.solve(A, np.ones(4))

# Einsum — matmul + contractions + transposes in one expression
X = np.random.rand(10, 3, 4)
Y = np.random.rand(10, 4, 5)
Z = np.einsum("bij,bjk->bik", X, Y)   # batched matmul
```

## Random numbers (new-style Generator API)

```python
rng = np.random.default_rng(seed=42)
rng.integers(0, 10, size=20)
rng.normal(loc=0, scale=1, size=(3, 3))
rng.choice(["red", "green", "blue"], size=5, replace=True)
rng.shuffle(rng.integers(0, 100, size=10))
```

## Stats

```python
x = rng.normal(0, 1, size=10_000)
x.mean(), x.std(), np.median(x), np.percentile(x, [5, 50, 95])
np.corrcoef(x, rng.normal(size=10_000))
np.histogram(x, bins=30)
```

## FFT

```python
t = np.linspace(0, 1, 1024, endpoint=False)
sig = np.sin(2*np.pi*50*t) + 0.5*np.sin(2*np.pi*120*t)
freqs = np.fft.rfftfreq(len(t), d=t[1]-t[0])
spectrum = np.abs(np.fft.rfft(sig))
```

## Broadcasting & vectorization

```python
# Pairwise euclidean distance without a single for-loop
A = rng.normal(size=(100, 3))
B = rng.normal(size=(50, 3))
dists = np.linalg.norm(A[:, None, :] - B[None, :, :], axis=2)  # (100, 50)
```

## Useful sub-modules

- **`numpy.linalg`** — matrix inverse, determinant, eig, SVD, solve, norm
- **`numpy.random`** — PRNG Generator, distributions, shuffling
- **`numpy.fft`** — FFT + inverse, real/complex variants
- **`numpy.ma`** — masked arrays (missing data)
- **`numpy.polynomial`** — polynomial fitting & manipulation
- **`numpy.lib.stride_tricks`** — advanced view tricks (sliding_window_view)

## iOS notes

- Full **OpenBLAS** is bundled — `np.linalg.solve()` on a 1000×1000 matrix runs in <0.1s on an M-series iPad.
- No GPU acceleration via numpy — use **torch** or **Metal** (via **moderngl**) for that.
- Saving `.npy` / `.npz` files to `~/Documents` works normally.
