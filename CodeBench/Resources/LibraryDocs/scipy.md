---
name: scipy
import: scipy
version: 1.15.0
category: Numerical Computing
tags: stats, optimize, interpolate, signal, linalg, sparse
bundled: true
---

# SciPy

**The other half of the scientific Python ecosystem.** Full iOS arm64 build with Fortran runtime stubs so arpack/propack/LAPACK-backed routines link cleanly.

## What's included

| Module | Purpose |
|---|---|
| `scipy.stats` | Probability distributions, hypothesis tests, descriptive stats |
| `scipy.optimize` | Minimisation, root finding, curve fitting, linprog |
| `scipy.interpolate` | 1D/ND interpolation, splines |
| `scipy.signal` | Filtering, spectral analysis, convolution, FFT |
| `scipy.linalg` | Dense linear algebra (more routines than numpy.linalg) |
| `scipy.sparse` | Sparse matrices + sparse linalg + graph algorithms |
| `scipy.integrate` | ODE solvers (ivp, odeint), quadrature |
| `scipy.spatial` | KD-trees, Voronoi, Delaunay, distance metrics |
| `scipy.special` | Bessel, gamma, error functions, orthogonal polynomials |
| `scipy.ndimage` | N-dimensional image filtering, morphology |

## Stats

```python
from scipy import stats
import numpy as np

rng = np.random.default_rng(42)
x = rng.normal(loc=5, scale=2, size=500)

# Fit a distribution
mu, sigma = stats.norm.fit(x)

# Hypothesis test
t, p = stats.ttest_1samp(x, popmean=5)
print(f"t={t:.3f}  p={p:.4f}")

# Correlations
y = 2 * x + rng.normal(size=500)
r, p = stats.pearsonr(x, y)
rho, p2 = stats.spearmanr(x, y)
```

## Optimize

```python
from scipy.optimize import minimize, curve_fit

# Minimize Rosenbrock
rosen = lambda x: sum(100*(x[1:] - x[:-1]**2)**2 + (1 - x[:-1])**2)
res = minimize(rosen, x0=[-1, 1, -1, 1], method="BFGS")
print(res.x)   # close to [1, 1, 1, 1]

# Curve fitting
def model(x, a, b): return a * np.exp(-b * x)
xd = np.linspace(0, 4, 50)
yd = model(xd, 2.5, 0.8) + rng.normal(scale=0.05, size=50)
popt, pcov = curve_fit(model, xd, yd)
```

## Signal processing

```python
from scipy import signal

fs = 1000                                 # 1 kHz
t = np.arange(0, 1, 1/fs)
x = np.sin(2*np.pi*50*t) + 0.5*np.sin(2*np.pi*120*t) + 0.3*rng.normal(size=fs)

# Low-pass Butterworth
b, a = signal.butter(4, 80, fs=fs, btype="low")
y = signal.filtfilt(b, a, x)

# Spectrogram
f, tt, Sxx = signal.spectrogram(x, fs=fs, nperseg=128)
```

## Interpolation

```python
from scipy.interpolate import interp1d, CubicSpline

x = np.linspace(0, 10, 11)
y = np.sin(x)
f_lin = interp1d(x, y, kind="linear")
f_cub = CubicSpline(x, y)

xq = np.linspace(0, 10, 500)
yq = f_cub(xq)
```

## Sparse matrices

```python
from scipy import sparse

A = sparse.random(1000, 1000, density=0.01, format="csr", random_state=0)
b = np.ones(1000)
from scipy.sparse.linalg import spsolve, eigsh
x = spsolve(A + sparse.eye(1000), b)
```

## ODE solving

```python
from scipy.integrate import solve_ivp

def lorenz(t, y, sigma=10, rho=28, beta=8/3):
    x, y_, z = y
    return [sigma*(y_ - x), x*(rho - z) - y_, x*y_ - beta*z]

sol = solve_ivp(lorenz, t_span=(0, 40), y0=[1, 1, 1], t_eval=np.linspace(0, 40, 5000))
```

## iOS notes

- Some Fortran routines (arpack eigensolver, SuperLU) depend on the bundled `libfortran_io_stubs.dylib`. It ships automatically — no action required.
- `scipy.weave` and `scipy.misc` are deprecated upstream and NOT available.
- `scipy.io.loadmat` works for reading MATLAB `.mat` files from Documents.
