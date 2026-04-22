---
name: plotly
import: plotly
version: 5.x
category: Plotting
tags: interactive, chart, web, dashboard
bundled: true
---

# Plotly

**Interactive, vector-perfect plotting.** The figures render to HTML+JS and show inside a WKWebView — pan, zoom, hover, export to PNG all work on-device.

## Quick start with plotly.express

```python
import plotly.express as px
import numpy as np

df_x = np.linspace(0, 10, 200)
df_y = np.sin(df_x) + 0.2 * np.random.default_rng(0).normal(size=200)

fig = px.scatter(x=df_x, y=df_y,
                 title="Noisy sine",
                 labels={"x": "time", "y": "signal"})
fig.show()
```

## Lower-level: graph_objects

```python
import plotly.graph_objects as go

fig = go.Figure()
fig.add_trace(go.Scatter(x=[1, 2, 3, 4], y=[10, 11, 13, 12], mode="lines+markers",
                         name="series A"))
fig.add_trace(go.Bar(x=["a", "b", "c"], y=[4, 7, 2], name="bars"))
fig.update_layout(title="Mixed plot",
                  xaxis_title="category",
                  yaxis_title="value",
                  template="plotly_dark")
fig.show()
```

## 3D surface

```python
x = np.linspace(-5, 5, 50)
y = np.linspace(-5, 5, 50)
xg, yg = np.meshgrid(x, y)
zg = np.sin(np.sqrt(xg**2 + yg**2))

fig = go.Figure(data=[go.Surface(z=zg, x=x, y=y, colorscale="Viridis")])
fig.update_layout(title="sin(r)", scene=dict(zaxis=dict(range=[-1.5, 1.5])))
fig.show()
```

## Subplots

```python
from plotly.subplots import make_subplots

fig = make_subplots(rows=1, cols=2, subplot_titles=("left", "right"))
fig.add_trace(go.Scatter(y=np.sin(x)), row=1, col=1)
fig.add_trace(go.Scatter(y=np.cos(x)), row=1, col=2)
fig.show()
```

## Choropleth / geo maps

```python
fig = px.choropleth(
    locations=["USA", "CAN", "MEX"],
    color=[10, 20, 15],
    color_continuous_scale="Blues",
    locationmode="ISO-3",
)
fig.show()
```

## Animations

```python
import plotly.express as px
# Any DataFrame-like dict works
rng = np.random.default_rng(0)
n = 100
frames = []
for step in range(20):
    frames.append({"x": rng.normal(size=n) + step*0.1,
                   "y": rng.normal(size=n),
                   "frame": step})
import pandas as pd  # if available in your install
# Or build it manually with plotly.graph_objects.Frame
```

## Saving

```python
# Static export (requires kaleido, bundled in Resources)
fig.write_image("/tmp/chart.png", width=900, height=500, scale=2)

# HTML export — keep interactivity in Documents/
fig.write_html("~/Documents/chart.html", include_plotlyjs="cdn")
```

## iOS notes

- `fig.show()` renders in a modal WKWebView pane inside the editor.
- JSON size cap: avoid rendering 1M+ data points; downsample first.
- `fig.write_image()` uses the bundled **kaleido** worker — the first call is slow (~1s) while kaleido boots.
