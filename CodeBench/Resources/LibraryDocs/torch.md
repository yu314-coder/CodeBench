---
name: torch
import: torch
version: 2.1.x
category: Machine Learning
tags: pytorch, tensor, nn, autograd, deep learning
bundled: true
---

# PyTorch

**Full native PyTorch build for iOS arm64**, with libtorch_python + libshm bundled. `torch.Tensor`, `torch.nn`, `torch.optim`, autograd, and the standard model-definition APIs all work; GPU acceleration goes via **MPS** (Metal Performance Shaders).

## Sanity check

Run the bundled `torch_test_all.py` in the Workspace — if the final `✓ ALL TESTS PASSED` line prints, torch is fully functional on this device.

## Tensors

```python
import torch

# Creation
x = torch.zeros(3, 3)
y = torch.arange(12, dtype=torch.float32).reshape(3, 4)
z = torch.randn(2, 5)

# Device placement — prefer MPS on iPad/iPhone
dev = torch.device("mps") if torch.backends.mps.is_available() else "cpu"
x = x.to(dev)

# Operators
(x + 1) * 2
x @ x.T                          # matrix multiplication
torch.cat([x, x], dim=0)
x.sum(dim=1, keepdim=True)
x.softmax(dim=-1)
```

## Autograd

```python
w = torch.randn(5, requires_grad=True)
x = torch.randn(5)
loss = (w * x).sum() ** 2
loss.backward()                  # fills w.grad
print(w.grad)
```

## Define a model (nn.Module)

```python
import torch.nn as nn
import torch.nn.functional as F

class MLP(nn.Module):
    def __init__(self, in_features=784, hidden=128, out=10):
        super().__init__()
        self.fc1 = nn.Linear(in_features, hidden)
        self.fc2 = nn.Linear(hidden, out)

    def forward(self, x):
        x = F.relu(self.fc1(x))
        return self.fc2(x)

net = MLP().to(dev)
print(sum(p.numel() for p in net.parameters()))   # 101 770
```

## Train loop

```python
from torch.utils.data import TensorDataset, DataLoader
import torch.optim as optim

# Fake data
X = torch.randn(1000, 20).to(dev)
y = (X.sum(dim=1) > 0).long().to(dev)

dl = DataLoader(TensorDataset(X, y), batch_size=64, shuffle=True)

model = MLP(20, 32, 2).to(dev)
opt = optim.Adam(model.parameters(), lr=1e-3)
loss_fn = nn.CrossEntropyLoss()

for epoch in range(5):
    for xb, yb in dl:
        opt.zero_grad()
        logits = model(xb)
        loss = loss_fn(logits, yb)
        loss.backward()
        opt.step()
    print(f"epoch {epoch} loss={loss.item():.4f}")
```

## Save / load

```python
torch.save(model.state_dict(), "/tmp/model.pt")
model.load_state_dict(torch.load("/tmp/model.pt"))
model.eval()
```

## Companion: transformers

The bundled `transformers` package works with `torch` for NLP pipelines (text generation, classification, embeddings). See `transformers.md`.

## iOS notes

- **MPS** (Metal) device works — big speedup vs CPU for conv nets. Falls back to CPU for ops MPS doesn't implement yet (rare).
- `torch.compile()` is NOT supported on iOS (no Triton backend). Stick with eager mode.
- TorchScript tracing works (`torch.jit.trace`); scripting has rough edges.
- `DataLoader(num_workers=n)` > 0 runs multi-process — on iOS use `num_workers=0`.
- Distributed training (DDP, RPC) is not supported.
- For portable inference, also see **ExecuTorch** (`.pte` models) in `torch_test_all.py`.
