---
name: sympy
import: sympy
version: 1.12+
category: Numerical Computing
tags: symbolic, algebra, calculus, equation
bundled: true
---

# SymPy

**Symbolic mathematics** — algebra, calculus, solving, pretty-printing. Pure Python so it works unchanged on iOS.

## Basic symbols & expressions

```python
import sympy as sp

x, y, z = sp.symbols("x y z")
expr = (x + y)**3
print(sp.expand(expr))       # x**3 + 3*x**2*y + 3*x*y**2 + y**3
print(sp.factor(x**3 - y**3)) # (x - y)*(x**2 + x*y + y**2)
print(sp.simplify(sp.sin(x)**2 + sp.cos(x)**2))  # 1
```

## Solving equations

```python
sp.solve(x**2 - 4, x)              # [-2, 2]
sp.solve([x + y - 3, x - y - 1], [x, y])  # {x: 2, y: 1}

# Differential equations
f = sp.Function("f")
sol = sp.dsolve(sp.Derivative(f(x), x) + f(x), f(x))
print(sol)    # Eq(f(x), C1*exp(-x))
```

## Calculus

```python
expr = sp.sin(x) * sp.exp(x)
print(sp.diff(expr, x))             # exp(x)*sin(x) + exp(x)*cos(x)
print(sp.diff(expr, x, 2))          # second derivative
print(sp.integrate(expr, x))
print(sp.integrate(expr, (x, 0, sp.pi)))  # definite integral

print(sp.limit(sp.sin(x)/x, x, 0))  # 1
print(sp.series(sp.cos(x), x, 0, 6))  # Taylor expansion
```

## Matrices

```python
M = sp.Matrix([[1, 2, 3], [4, 5, 6], [7, 8, 10]])
print(M.det())
print(M.inv())
print(M.eigenvals())
```

## LaTeX output

```python
expr = sp.Integral(sp.cos(x) * sp.exp(-x**2), (x, -sp.oo, sp.oo))
print(sp.latex(expr))
# → \int\limits_{-\infty}^{\infty} e^{- x^{2}} \cos{\left(x \right)}\, dx
```

Pair with **manim**'s `MathTex` or the LaTeX preview pane to render the expression graphically.

## Convert to a fast numerical function

```python
f = sp.lambdify(x, sp.exp(-x**2/2) / sp.sqrt(2*sp.pi), modules="numpy")
import numpy as np
print(f(np.linspace(-3, 3, 7)))
```

## Useful tricks

```python
# Convert a symbolic expression to Python code
print(sp.pycode(sp.sin(x) + x**2))  # 'math.sin(x) + x**2'

# Sympy assumptions
x_pos = sp.symbols("x", positive=True)
sp.sqrt(x_pos**2)   # x (not |x|)
```

## iOS notes

- Pure Python — slower than numpy for numerical work, but unmatched for symbolic reasoning.
- Integrates with **manim** for animated math proofs and with our **LaTeX preview** for publication-quality output.
- Plots via `sympy.plot()` go through matplotlib → plotly (see `matplotlib.md`).
