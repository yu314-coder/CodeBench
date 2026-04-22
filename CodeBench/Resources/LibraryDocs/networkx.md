---
name: networkx
import: networkx
version: 3.x
category: Numerical Computing
tags: graph, network, algorithm, shortest-path
bundled: true
---

# NetworkX

**Graphs and network analysis in pure Python.** Build, query, traverse, and analyse graphs with hundreds of classical algorithms.

## Create a graph

```python
import networkx as nx

G = nx.Graph()                  # undirected
G.add_edge("A", "B", weight=3)
G.add_edge("B", "C", weight=5)
G.add_edge("A", "C", weight=8)
G.add_node("D")                 # isolated

print(list(G.nodes))            # ['A', 'B', 'C', 'D']
print(list(G.edges(data=True))) # [('A', 'B', {'weight': 3}), ...]

# Directed variant
D = nx.DiGraph()
D.add_edge("A", "B")
```

## Shortest paths

```python
# Unweighted BFS
path = nx.shortest_path(G, "A", "C")                  # ['A', 'B', 'C'] or ['A', 'C']

# Weighted Dijkstra
path = nx.dijkstra_path(G, "A", "C", weight="weight") # ['A', 'B', 'C'] (weight 8)
dist = nx.single_source_dijkstra_path_length(G, "A", weight="weight")
```

## Centrality

```python
nx.degree_centrality(G)
nx.betweenness_centrality(G)
nx.closeness_centrality(G)
nx.eigenvector_centrality(G, max_iter=1000)
nx.pagerank(G)
```

## Generators

```python
nx.complete_graph(5)
nx.erdos_renyi_graph(20, 0.2, seed=0)
nx.barabasi_albert_graph(20, m=2, seed=0)
nx.grid_2d_graph(5, 5)
nx.karate_club_graph()
```

## Components / connectivity

```python
nx.connected_components(G)     # iterator of sets
nx.number_connected_components(G)

# Strongly/weakly connected on DiGraph
list(nx.strongly_connected_components(D))
```

## Cycles / trees / flow

```python
nx.find_cycle(D)                      # find a cycle
nx.minimum_spanning_tree(G)           # MST (Kruskal / Prim)
flow_value, flow = nx.maximum_flow(D, "A", "C", capacity="weight")
```

## Visualize (via matplotlib / plotly)

```python
import matplotlib.pyplot as plt

pos = nx.spring_layout(G, seed=0)
nx.draw_networkx_nodes(G, pos, node_color="#60a5fa", node_size=500)
nx.draw_networkx_labels(G, pos)
nx.draw_networkx_edges(G, pos, width=2, alpha=0.7)
nx.draw_networkx_edge_labels(G, pos, edge_labels=nx.get_edge_attributes(G, "weight"))
plt.axis("off")
plt.show()
```

## Save / load

```python
nx.write_graphml(G, "/tmp/g.graphml")
G2 = nx.read_graphml("/tmp/g.graphml")

# JSON
import json
data = nx.node_link_data(G)
json.dump(data, open("/tmp/g.json", "w"))
```

## iOS notes

- Pure Python — no native deps. Scales fine to graphs with ~100k nodes; for millions of nodes use scipy.sparse matrices + `networkx.from_scipy_sparse_array()`.
- For interactive graph viz, pair with **plotly** (hover + zoom) instead of matplotlib.
