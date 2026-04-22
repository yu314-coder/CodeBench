---
name: matplotlib
import: matplotlib
version: plotly-backed
category: Plotting
tags: plot, chart, figure, axes
bundled: true
---

# matplotlib (plotly-backed)

**OfflinAi's matplotlib module is a plotly-powered drop-in** that renders charts using plotly.js in a WKWebView behind the scenes, since running the real mpl backends on iOS is fragile. The pyplot API you're used to still works for the common cases (line, scatter, bar, histogram, subplots, annotations, titles, axes).

If you need a real native matplotlib backend, bundle one yourself via `Frameworks/`.

## Quick line plot

```python
import matplotlib.pyplot as plt
import numpy as np

x = np.linspace(0, 2*np.pi, 200)
plt.figure(figsize=(8, 3))
plt.plot(x, np.sin(x), label="sin")
plt.plot(x, np.cos(x), label="cos", linestyle="--")
plt.title("Trig functions")
plt.xlabel("x"); plt.ylabel("y")
plt.legend()
plt.grid(True)
plt.show()
```

## Scatter + color

```python
rng = np.random.default_rng(0)
x, y, c = rng.normal(size=(3, 200))
plt.scatter(x, y, c=c, cmap="viridis", alpha=0.7)
plt.colorbar(label="z-value")
plt.show()
```

## Bar chart

```python
cats = ["A", "B", "C", "D", "E"]
vals = [23, 17, 35, 29, 12]
plt.bar(cats, vals, color=["#60a5fa", "#34d399", "#fbbf24", "#f87171", "#a78bfa"])
plt.ylabel("count")
plt.show()
```

## Histogram

```python
data = rng.normal(loc=5, scale=1.5, size=5000)
plt.hist(data, bins=40, edgecolor="white", alpha=0.85)
plt.title("Sampling distribution")
plt.show()
```

## Subplots

```python
fig, axes = plt.subplots(2, 2, figsize=(9, 6))
axes[0, 0].plot(x, np.sin(x));        axes[0, 0].set_title("sin")
axes[0, 1].plot(x, np.cos(x));        axes[0, 1].set_title("cos")
axes[1, 0].scatter(x, np.tan(x), s=5); axes[1, 0].set_title("tan")
axes[1, 1].plot(x, np.exp(-x/4));     axes[1, 1].set_title("decay")
plt.tight_layout()
plt.show()
```

## Saving figures

```python
# PNG export (rasterised) works
plt.savefig("/tmp/chart.png", dpi=150)

# SVG export also works — the plotly backend writes vector SVG
plt.savefig("/tmp/chart.svg")
```

## iOS notes

- `plt.show()` pops a preview inside the editor (plotly HTML rendered in a WKWebView).
- `plt.savefig("name.png")` writes to your Documents folder — it shows up in the Files tab.
- Seaborn-style hex strings (`"#60a5fa"`) work everywhere.
- Animations (`FuncAnimation`) are NOT supported — for animated output use manim.

## Companion library

For fully interactive + vector-perfect plots, use **plotly** directly (see `plotly.md`). It's the backend anyway.
