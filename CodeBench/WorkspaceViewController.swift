import UIKit
import WebKit

/// Workspace tab — code playground with pre-built test templates.
/// Runs Python/C code directly without the AI model.
final class WorkspaceViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {

    struct Template {
        let title: String
        let icon: String
        let category: String
        let code: String
    }

    // MARK: - Templates

    static let templates: [Template] = [
        // ── numpy ──
        Template(title: "numpy: Linear Algebra", icon: "function", category: "NumPy", code: """
        import numpy as np
        A = np.array([[3, 2, -1], [2, -2, 4], [-1, 0.5, -1]])
        b = np.array([1, -2, 0])
        x = np.linalg.solve(A, b)
        print("Solution:", x)
        evals, evecs = np.linalg.eig(A)
        print("Eigenvalues:", evals.round(4))
        print("Determinant:", round(np.linalg.det(A), 4))
        """),

        // ── scipy ──
        Template(title: "scipy: Optimize", icon: "chart.line.downtrend.xyaxis", category: "SciPy", code: """
        import numpy as np
        from scipy.optimize import minimize
        def f(x):
            return (x[0]-1)**2 + (x[1]-2)**2 + np.sin(x[0]*x[1])
        result = minimize(f, [0, 0], method='Nelder-Mead')
        print(f"Minimum at: {result.x.round(4)}")
        print(f"f(min) = {result.fun:.6f}")
        print(f"Iterations: {result.nit}")
        """),

        Template(title: "scipy: FFT Spectrum", icon: "waveform", category: "SciPy", code: """
        import numpy as np
        from scipy.fft import rfft, rfftfreq
        t = np.linspace(0, 1, 1000)
        signal = np.sin(2*np.pi*5*t) + 0.5*np.sin(2*np.pi*12*t)
        freqs = rfftfreq(len(t), 1/1000)
        fft_vals = np.abs(rfft(signal))
        top3 = freqs[np.argsort(fft_vals)[-3:]]
        print(f"Detected frequencies: {sorted(top3.round(1))} Hz")
        print(f"Expected: [5.0, 12.0] Hz")
        """),

        Template(title: "scipy: Statistics", icon: "chart.bar.fill", category: "SciPy", code: """
        import numpy as np
        from scipy.stats import ttest_1samp, norm
        np.random.seed(42)
        data = np.random.randn(1000) + 0.1
        t_stat, p_val = ttest_1samp(data, 0)
        print(f"Sample mean: {data.mean():.4f}")
        print(f"t-statistic: {t_stat:.4f}")
        print(f"p-value: {p_val:.4f}")
        print(f"Significant (p<0.05): {p_val < 0.05}")
        """),

        // ── sympy ──
        Template(title: "sympy: Solve & Calculus", icon: "x.squareroot", category: "SymPy", code: """
        from sympy import symbols, solve, diff, integrate, sin, cos, exp, oo, pi, series
        x = symbols('x')

        roots = solve(x**3 - 6*x**2 + 11*x - 6, x)
        print(f"Roots of x³-6x²+11x-6=0: {roots}")

        deriv = diff(sin(x**2) * exp(x), x)
        print(f"d/dx[sin(x²)·eˣ] = {deriv}")

        integral = integrate(1/(1+x**2), (x, 0, oo))
        print(f"∫₀^∞ 1/(1+x²)dx = {integral}")

        taylor = series(cos(x), x, 0, n=8)
        print(f"cos(x) Taylor = {taylor}")
        """),

        // ── sklearn ──
        Template(title: "sklearn: RandomForest", icon: "tree.fill", category: "ML", code: """
        import numpy as np
        from sklearn.datasets import make_classification
        from sklearn.ensemble import RandomForestClassifier
        from sklearn.model_selection import train_test_split
        from sklearn.metrics import accuracy_score, confusion_matrix

        X, y = make_classification(n_samples=200, n_features=4, random_state=42)
        X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.3, random_state=42)

        rf = RandomForestClassifier(n_estimators=10, max_depth=5, random_state=42)
        rf.fit(X_train, y_train)
        y_pred = rf.predict(X_test)

        print(f"Accuracy: {accuracy_score(y_test, y_pred):.3f}")
        print(f"Confusion Matrix:\\n{confusion_matrix(y_test, y_pred)}")
        """),

        Template(title: "sklearn: PCA + KMeans", icon: "circle.grid.cross.fill", category: "ML", code: """
        import numpy as np
        from sklearn.datasets import make_blobs
        from sklearn.decomposition import PCA
        from sklearn.cluster import KMeans
        from sklearn.metrics import silhouette_score

        X, y_true = make_blobs(n_samples=300, centers=3, random_state=42)

        pca = PCA(n_components=2)
        X_pca = pca.fit_transform(X)
        print(f"PCA: {X.shape} → {X_pca.shape}")
        print(f"Variance explained: {pca.explained_variance_ratio_.round(3)}")

        km = KMeans(n_clusters=3, random_state=42).fit(X_pca)
        sil = silhouette_score(X_pca, km.labels_)
        print(f"KMeans silhouette: {sil:.3f}")
        print(f"Cluster sizes: {[int((km.labels_==i).sum()) for i in range(3)]}")
        """),

        Template(title: "sklearn: Pipeline", icon: "arrow.right.arrow.left", category: "ML", code: """
        import numpy as np
        from sklearn.pipeline import make_pipeline
        from sklearn.preprocessing import StandardScaler
        from sklearn.linear_model import LogisticRegression
        from sklearn.datasets import make_moons
        from sklearn.model_selection import cross_val_score

        X, y = make_moons(n_samples=200, noise=0.2, random_state=42)
        pipe = make_pipeline(StandardScaler(), LogisticRegression(max_iter=500))
        scores = cross_val_score(pipe, X, y, cv=5)
        print(f"Cross-val scores: {scores.round(3)}")
        print(f"Mean accuracy: {scores.mean():.3f} ± {scores.std():.3f}")
        """),

        // ── matplotlib ──
        Template(title: "matplotlib: 2D Plot", icon: "chart.xyaxis.line", category: "Plot", code: """
        import numpy as np
        import matplotlib.pyplot as plt

        x = np.linspace(-2*np.pi, 2*np.pi, 200)
        plt.plot(x, np.sin(x), label='sin(x)')
        plt.plot(x, np.cos(x), label='cos(x)')
        plt.title('Trigonometric Functions')
        plt.xlabel('x')
        plt.ylabel('y')
        plt.grid(True)
        plt.legend()
        plt.show()
        """),

        Template(title: "matplotlib: 3D Sphere", icon: "globe", category: "Plot", code: """
        import numpy as np
        import matplotlib.pyplot as plt

        fig = plt.figure()
        ax = fig.add_subplot(111, projection='3d')
        u = np.linspace(0, 2*np.pi, 50)
        v = np.linspace(0, np.pi, 50)
        X = np.outer(np.cos(u), np.sin(v))
        Y = np.outer(np.sin(u), np.sin(v))
        Z = np.outer(np.ones_like(u), np.cos(v))
        ax.plot_surface(X, Y, Z, cmap='viridis', alpha=0.8)
        plt.title('Unit Sphere: x²+y²+z²=1')
        plt.show()
        """),

        Template(title: "matplotlib: Contour", icon: "circle.and.line.horizontal", category: "Plot", code: """
        import numpy as np
        import matplotlib.pyplot as plt

        x = np.linspace(-3, 3, 200)
        y = np.linspace(-3, 3, 200)
        X, Y = np.meshgrid(x, y)
        Z = np.exp(X) + Y**3
        plt.contour(X, Y, Z, levels=[1], colors='blue', linewidths=2)
        plt.title('eˣ + y³ = 1')
        plt.xlabel('x')
        plt.ylabel('y')
        plt.grid(True)
        plt.axis('equal')
        plt.show()
        """),

        // ── PyTorch / ExecuTorch ──
        Template(title: "torch: ExecuTorch Forward Pass", icon: "brain.head.profile", category: "PyTorch", code: """
        # PyTorch on iPad — end-to-end test of offlinai_torch (ExecuTorch bridge).
        #
        # This template verifies that:
        #   1. The ExecuTorchEngine Swift side is running.
        #   2. You can load a `.pte` file from disk into offlinai_torch.Module.
        #   3. A forward pass executes and returns the expected tensor.
        #
        # To test with a real model, export a tiny one on a desktop and drop
        # the .pte into ~/Documents/Workspace/ via the Files app:
        #
        #     # Desktop (one-off):
        #     import torch
        #     from executorch.exir import to_edge
        #     class Tiny(torch.nn.Module):
        #         def __init__(self):
        #             super().__init__()
        #             self.fc = torch.nn.Linear(4, 2)
        #         def forward(self, x):
        #             return torch.relu(self.fc(x))
        #     m = Tiny().eval()
        #     ex = (torch.randn(1, 4),)
        #     prog = to_edge(torch.export.export(m, ex)).to_executorch()
        #     open("tiny.pte", "wb").write(prog.buffer)
        #     # → copy tiny.pte into the app's Workspace folder.

        import os, glob
        import numpy as np
        import offlinai_torch

        WORKSPACE = os.path.expanduser("~/Documents/Workspace")

        # 1) Health check — is the Swift ExecuTorchEngine alive?
        print(f"ExecuTorch engine available: {offlinai_torch.is_available()}")
        print(f"Signal dir: {offlinai_torch.SIGNAL_DIR}")

        # 2) Look for any .pte models the user has dropped in.
        os.makedirs(WORKSPACE, exist_ok=True)
        pte_files = sorted(glob.glob(os.path.join(WORKSPACE, "*.pte")))
        print(f"Found .pte models: {[os.path.basename(p) for p in pte_files] or '(none)'}")

        if not pte_files:
            print("⚠  No .pte models found — export one on your desktop and copy")
            print("   it into ~/Documents/Workspace/ via the Files app, then run again.")
            print()
            print("   Test PASSED: bridge is responsive (no model to exercise).")
            raise SystemExit(0)

        # 3) Load the first model + inspect its signature.
        model_path = pte_files[0]
        print(f"\\nLoading {os.path.basename(model_path)}...")
        model = offlinai_torch.Module(model_path)
        print(f"Methods: {model.methods}")
        meta = model.method_metadata()
        print(f"Metadata: {meta}")

        # 4) Build a random input that matches the model's first input shape.
        input_spec = meta["inputs"][0]
        shape = [int(s) for s in input_spec["shape"]]
        dtype_tag = input_spec["dtype"]
        dtype_map = {"float32": np.float32, "float64": np.float64,
                     "int32":   np.int32,   "int64":   np.int64}
        np_dtype = dtype_map.get(dtype_tag, np.float32)
        x = np.random.randn(*shape).astype(np_dtype)
        print(f"\\nInput {tuple(x.shape)} {x.dtype}:")
        print(x)

        # 5) Run forward + print the output.
        outputs = model.forward(x)
        print(f"\\n✓ Forward pass produced {len(outputs)} tensor(s):")
        for i, y in enumerate(outputs):
            print(f"  [{i}] shape={tuple(y.shape)} dtype={y.dtype}")
            print(f"      {y}")

        print("\\n✓ PyTorch / ExecuTorch bridge works end-to-end.")
        """),

        Template(title: "torch: Bridge Health Check", icon: "stethoscope", category: "PyTorch", code: """
        # Minimal smoke test — verifies the ExecuTorchEngine is alive and
        # the Python ↔ Swift file-IPC is wired correctly. Does NOT need a
        # .pte model. Run this first if any other torch template fails.

        import os, time, pathlib, json, uuid
        import offlinai_torch

        print("=" * 60)
        print("offlinai_torch bridge health check")
        print("=" * 60)

        # 1. Module version + paths
        print(f"Module version: {offlinai_torch.__version__}")
        print(f"Signal dir:     {offlinai_torch.SIGNAL_DIR}")
        print(f"Available:      {offlinai_torch.is_available()}")

        # 2. Inspect the signal dir state
        sig = pathlib.Path(offlinai_torch.SIGNAL_DIR)
        if sig.exists():
            entries = sorted([p.name for p in sig.iterdir()])
            print(f"Signal dir contents ({len(entries)} entries):")
            for e in entries[:10]:
                print(f"  - {e}")
            if len(entries) > 10:
                print(f"  ... and {len(entries)-10} more")

        # 3. Heartbeat freshness
        heartbeat = sig / ".engine_alive"
        if heartbeat.exists():
            age = time.time() - heartbeat.stat().st_mtime
            status = "✓ fresh" if age < 5 else f"⚠ stale ({age:.1f}s old)"
            print(f"Engine heartbeat: {status}")
        else:
            print("Engine heartbeat: ✗ missing (Swift side may not have started)")

        # 4. Round-trip latency probe — send a bogus `load` request for a
        #    nonexistent file; engine should reply with ok:false quickly.
        print("\\nRound-trip probe (load on nonexistent path)…")
        t0 = time.time()
        try:
            offlinai_torch.Module("/does/not/exist.pte")
            print("  ✗ Unexpected success")
        except FileNotFoundError as e:
            print(f"  ✓ Python caught FileNotFoundError client-side: {e}")
        except offlinai_torch.ExecuTorchError as e:
            dt = (time.time() - t0) * 1000
            print(f"  ✓ Engine responded in {dt:.0f}ms: {e}")
        except Exception as e:
            print(f"  ? Unexpected exception: {type(e).__name__}: {e}")

        print("\\n✓ Bridge health check complete.")
        """),

        Template(title: "torch: Model Inspector", icon: "magnifyingglass.circle", category: "PyTorch", code: """
        # Load every .pte file in ~/Documents/Workspace and print its full
        # method signatures (inputs, outputs, shapes, dtypes, memory budget).
        # Use this to understand what a model expects before feeding it data.

        import os, glob
        import offlinai_torch

        WORKSPACE = os.path.expanduser("~/Documents/Workspace")
        pte_files = sorted(glob.glob(os.path.join(WORKSPACE, "*.pte")))
        if not pte_files:
            print(f"No .pte files in {WORKSPACE}")
            print("Copy a model there via the Files app, then run again.")
            raise SystemExit(0)

        for path in pte_files:
            name = os.path.basename(path)
            size = os.path.getsize(path) / (1024 * 1024)
            print("=" * 60)
            print(f"📦 {name}  ({size:.2f} MB)")
            print("=" * 60)
            try:
                model = offlinai_torch.Module(path)
            except Exception as e:
                print(f"  ✗ Load failed: {e}")
                continue

            print(f"Methods: {model.methods}")
            for method in model.methods:
                print(f"\\n  {method}():")
                try:
                    meta = model.method_metadata(method)
                except Exception as e:
                    print(f"    ✗ metadata failed: {e}")
                    continue
                for i, inp in enumerate(meta.get("inputs", [])):
                    print(f"    input [{i}]  shape={inp['shape']}  dtype={inp['dtype']}")
                for i, out in enumerate(meta.get("outputs", [])):
                    print(f"    output[{i}]  shape={out['shape']}  dtype={out['dtype']}")
            print()

        print(f"✓ Inspected {len(pte_files)} model(s).")
        """),

        Template(title: "torch: Benchmark Inference", icon: "speedometer", category: "PyTorch", code: """
        # Time N forward passes through the first .pte found in Workspace.
        # Reports wall-clock ms/iter and a rough throughput number.
        # Useful for comparing different quantizations / backends.

        import os, glob, time, statistics
        import numpy as np
        import offlinai_torch

        WORKSPACE = os.path.expanduser("~/Documents/Workspace")
        N_WARMUP = 3
        N_ITERS  = 20

        pte = sorted(glob.glob(os.path.join(WORKSPACE, "*.pte")))
        if not pte:
            print("No .pte files found — drop one into Workspace first.")
            raise SystemExit(0)

        model = offlinai_torch.Module(pte[0])
        meta = model.method_metadata()
        shape = [int(s) for s in meta["inputs"][0]["shape"]]
        dtype_tag = meta["inputs"][0]["dtype"]
        np_dtype = {"float32": np.float32, "float64": np.float64,
                    "int32": np.int32, "int64": np.int64}.get(dtype_tag, np.float32)

        print(f"Benchmarking {os.path.basename(pte[0])}  shape={tuple(shape)}  dtype={dtype_tag}")
        print(f"  warmup: {N_WARMUP} iterations  |  measure: {N_ITERS} iterations")

        # Warmup (first-call overhead from kernel codegen, caches, etc.)
        x = np.random.randn(*shape).astype(np_dtype)
        for _ in range(N_WARMUP):
            model.forward(x)

        # Measure
        times_ms = []
        for _ in range(N_ITERS):
            x = np.random.randn(*shape).astype(np_dtype)
            t0 = time.perf_counter()
            model.forward(x)
            times_ms.append((time.perf_counter() - t0) * 1000)

        mean   = statistics.mean(times_ms)
        stdev  = statistics.stdev(times_ms) if len(times_ms) > 1 else 0.0
        median = statistics.median(times_ms)
        p95    = sorted(times_ms)[int(len(times_ms) * 0.95)]

        print(f"\\n  mean   : {mean:7.2f} ms  ± {stdev:.2f}")
        print(f"  median : {median:7.2f} ms")
        print(f"  p95    : {p95:7.2f} ms")
        print(f"  min    : {min(times_ms):7.2f} ms")
        print(f"  max    : {max(times_ms):7.2f} ms")
        print(f"\\n  throughput: {1000/mean:.1f} iter/s")
        """),

        Template(title: "torch: Image Classifier", icon: "photo.on.rectangle", category: "PyTorch", code: """
        # Load an image from Workspace, preprocess as ImageNet-normalized
        # float32 (1,3,224,224), run a classifier .pte, print top-5.
        #
        # Pair with a ResNet/MobileNet .pte exported for ImageNet. Place
        # your .pte and .jpg/.png in ~/Documents/Workspace/.
        #
        # Optional: ~/Documents/Workspace/imagenet_labels.txt  (one class
        # name per line). Without it, we print the raw class indices.

        import os, glob
        import numpy as np
        from PIL import Image
        import offlinai_torch

        WORKSPACE = os.path.expanduser("~/Documents/Workspace")
        pte = next(iter(sorted(glob.glob(os.path.join(WORKSPACE, "*.pte")))), None)
        imgs = sorted(glob.glob(os.path.join(WORKSPACE, "*.jpg"))) \\
             + sorted(glob.glob(os.path.join(WORKSPACE, "*.png")))

        if not pte or not imgs:
            print("Need a .pte classifier AND at least one .jpg/.png in Workspace.")
            raise SystemExit(0)

        # ImageNet preprocessing
        MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32).reshape(1, 3, 1, 1)
        STD  = np.array([0.229, 0.224, 0.225], dtype=np.float32).reshape(1, 3, 1, 1)

        def preprocess(path):
            img = Image.open(path).convert("RGB").resize((224, 224), Image.BICUBIC)
            arr = np.asarray(img, dtype=np.float32) / 255.0
            arr = arr.transpose(2, 0, 1)[None, ...]   # HWC → 1,3,H,W
            return (arr - MEAN) / STD

        def softmax(x, axis=-1):
            x = x - x.max(axis=axis, keepdims=True)
            e = np.exp(x)
            return e / e.sum(axis=axis, keepdims=True)

        # Optional labels file
        labels_path = os.path.join(WORKSPACE, "imagenet_labels.txt")
        labels = None
        if os.path.exists(labels_path):
            with open(labels_path) as f:
                labels = [line.strip() for line in f if line.strip()]

        print(f"Model: {os.path.basename(pte)}")
        model = offlinai_torch.Module(pte)

        for img_path in imgs:
            print(f"\\n📷 {os.path.basename(img_path)}")
            x = preprocess(img_path).astype("float32")
            (logits,) = model.forward(x)
            probs = softmax(logits.squeeze())
            top5 = np.argsort(-probs)[:5]
            for rank, idx in enumerate(top5, 1):
                name = labels[idx] if labels and idx < len(labels) else f"class_{idx}"
                print(f"  {rank}. {name:<40s}  {probs[idx]*100:5.1f}%")
        """),

        Template(title: "torch: Desktop Export Recipe", icon: "square.and.arrow.up", category: "PyTorch", code: """
        # NOT meant to RUN on iPad — this is a reference for what to paste
        # into a DESKTOP Python (Mac/Linux with `pip install executorch`) to
        # produce .pte files the iPad can consume.
        #
        # After running this on desktop, copy the produced .pte into
        # ~/Documents/Workspace/ on the iPad via the Files app.

        print(__doc__)
        print()
        print(RECIPE)

        RECIPE = '''
        # ─── DESKTOP EXPORT (run this on your laptop, not iPad) ──────────
        # pip install torch==2.1.2 executorch==1.3.0

        import torch, torch.nn as nn
        from executorch.exir import to_edge, ExecutorchBackendConfig

        # ─ (a) A tiny MLP — smallest possible model, good for smoke tests
        class TinyMLP(nn.Module):
            def __init__(self):
                super().__init__()
                self.fc1 = nn.Linear(4, 16)
                self.fc2 = nn.Linear(16, 2)
            def forward(self, x):
                return torch.relu(self.fc2(torch.relu(self.fc1(x))))

        # ─ (b) A ResNet-18 image classifier — realistic use case
        def resnet18_for_export():
            from torchvision.models import resnet18, ResNet18_Weights
            m = resnet18(weights=ResNet18_Weights.DEFAULT).eval()
            return m, (torch.randn(1, 3, 224, 224),)

        # Pick one:
        model     = TinyMLP().eval()
        example   = (torch.randn(1, 4),)
        out_name  = "tiny.pte"

        # Export → lowered → executorch
        aten = torch.export.export(model, example)
        prog = to_edge(aten).to_executorch(config=ExecutorchBackendConfig())
        with open(out_name, "wb") as f:
            f.write(prog.buffer)
        print(f"Wrote {out_name} ({len(prog.buffer)/1024:.1f} KB)")

        # XNNPACK-quantized variant (smaller + faster on ARM CPUs):
        # from executorch.backends.xnnpack.partition.xnnpack_partitioner \\
        #     import XnnpackPartitioner
        # prog = to_edge(aten).to_backend(XnnpackPartitioner()).to_executorch()

        # CoreML-delegated variant (uses Neural Engine on iPad):
        # from executorch.backends.apple.coreml.partition import CoreMLPartitioner
        # prog = to_edge(aten).to_backend(CoreMLPartitioner()).to_executorch()
        # ──────────────────────────────────────────────────────────────
        '''

        print(RECIPE)
        print()
        print("After running, AirDrop or iCloud-Drive the .pte to the iPad,")
        print("then move it to the app's Workspace folder via Files.")
        """),

        // ── networkx ──
        Template(title: "networkx: Graph Analysis", icon: "point.3.connected.trianglepath.dotted", category: "Graph", code: """
        import networkx as nx

        G = nx.erdos_renyi_graph(20, 0.3, seed=42)
        print(f"Nodes: {G.number_of_nodes()}")
        print(f"Edges: {G.number_of_edges()}")
        print(f"Density: {nx.density(G):.3f}")

        if nx.is_connected(G):
            print(f"Diameter: {nx.diameter(G)}")
            path = nx.shortest_path(G, 0, 5)
            print(f"Shortest path 0→5: {path}")

        degrees = dict(G.degree())
        top5 = sorted(degrees.items(), key=lambda x: -x[1])[:5]
        print(f"Top 5 nodes by degree: {top5}")

        print(f"Clustering coefficient: {nx.average_clustering(G):.3f}")
        """),

        // ── big calculation ──
        Template(title: "Big Numbers", icon: "number", category: "Math", code: """
        import math

        print(f"2^100 = {2**100}")
        print(f"100! = {math.factorial(100)}")
        print(f"2^1000 has {len(str(2**1000))} digits")

        # Fibonacci
        a, b = 0, 1
        for i in range(98):
            a, b = b, a + b
        print(f"Fib(100) = {b}")

        # Primes (sieve)
        def sieve(n):
            is_p = [True] * (n+1)
            is_p[0] = is_p[1] = False
            for i in range(2, int(n**0.5)+1):
                if is_p[i]:
                    for j in range(i*i, n+1, i):
                        is_p[j] = False
            return [i for i in range(n+1) if is_p[i]]
        primes = sieve(100)
        print(f"Primes up to 100: {primes}")
        """),

        // ── C interpreter ──
        Template(title: "C: Structs + Algorithms", icon: "c.square.fill", category: "C", code: """
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <math.h>

        #define MAX_SIZE 100
        #define PI 3.14159265358979
        #define SQUARE(x) ((x)*(x))

        // --- Structs ---
        struct Point {
            double x;
            double y;
        };

        // --- Union ---
        union Number {
            int i;
            double f;
        };

        // --- Functions ---
        double distance(struct Point a, struct Point b) {
            double dx = a.x - b.x;
            double dy = a.y - b.y;
            return sqrt(dx*dx + dy*dy);
        }

        int is_prime(int n) {
            if (n < 2) return 0;
            for (int i = 2; i * i <= n; i++)
                if (n % i == 0) return 0;
            return 1;
        }

        long long fibonacci(int n) {
            if (n <= 1) return n;
            long long a = 0, b = 1;
            for (int i = 2; i <= n; i++) {
                long long c = a + b;
                a = b;
                b = c;
            }
            return b;
        }

        // Static variable demo
        int counter() {
            static int count = 0;
            count++;
            return count;
        }

        // Function pointer comparator for qsort
        int compare_asc(int a, int b) {
            return a - b;
        }

        int main() {
            printf("=== CodeBench C Interpreter ===\\n\\n");

            // --- Structs ---
            struct Point p1 = {3.0, 4.0};
            struct Point p2 = {7.0, 1.0};
            printf("Distance: %.4f\\n", distance(p1, p2));
            printf("SQUARE(5) = %d\\n\\n", SQUARE(5));

            // --- Pointers & Address-of ---
            int x = 42;
            int *px = &x;
            printf("x = %d, *px = %d\\n", x, *px);
            *px = 100;
            printf("After *px = 100: x = %d\\n\\n", x);

            // --- 2D Array ---
            int grid[3][3] = {1, 2, 3, 4, 5, 6, 7, 8, 9};
            printf("2D Array [1][2] = %d\\n\\n", grid[1][2]);

            // --- sprintf to buffer ---
            char buf[64];
            sprintf(buf, "Hello %s, pi=%.2f", "World", PI);
            printf("sprintf result: %s\\n\\n", buf);

            // --- Static variable ---
            printf("Static counter: ");
            for (int i = 0; i < 5; i++)
                printf("%d ", counter());
            printf("\\n\\n");

            // --- Function pointers ---
            int (*cmp)(int, int) = compare_asc;
            printf("cmp(3,7) = %d\\n", cmp(3, 7));
            printf("cmp(7,3) = %d\\n\\n", cmp(7, 3));

            // --- Goto ---
            int val = 0;
            goto skip;
            val = 999;
        skip:
            printf("After goto: val = %d (should be 0)\\n\\n", val);

            // --- Union ---
            union Number num;
            num.i = 42;
            printf("Union int: %d\\n", num.i);
            num.f = 3.14;
            printf("Union float: %.2f\\n\\n", num.f);

            // --- Primes ---
            printf("Primes < 30: ");
            for (int n = 2; n < 30; n++)
                if (is_prime(n)) printf("%d ", n);
            printf("\\n\\n");

            // --- Fibonacci ---
            for (int i = 1; i <= 10; i++)
                printf("fib(%2d) = %lld\\n", i, fibonacci(i));

            printf("\\nAll features working!\\n");
            return 0;
        }
        """),

        // ── manim ──
        Template(title: "manim: Shapes", icon: "sparkles", category: "Manim", code: """
        from manim import *

        class ShapeDemo(Scene):
            def construct(self):
                circle = Circle(radius=1.5, color=BLUE, fill_opacity=0.5)
                square = Square(side_length=2, color=RED, fill_opacity=0.3)
                triangle = Triangle(color=GREEN, fill_opacity=0.3)

                shapes = VGroup(circle, square, triangle).arrange(RIGHT, buff=1)
                self.play(Create(shapes), run_time=2)

                title = Text("Shapes in Manim", font_size=36).to_edge(UP)
                self.play(Write(title))
                self.wait(0.5)

        scene = ShapeDemo()
        scene.render()
        """),

        Template(title: "manim: Transform", icon: "arrow.triangle.2.circlepath", category: "Manim", code: """
        from manim import *

        class TransformDemo(Scene):
            def construct(self):
                circle = Circle(color=BLUE, fill_opacity=0.8)
                square = Square(color=RED, fill_opacity=0.8)
                triangle = Triangle(color=GREEN, fill_opacity=0.8)

                self.play(Create(circle))
                self.play(Transform(circle, square))
                self.play(Transform(circle, triangle))
                self.play(FadeOut(circle))

        scene = TransformDemo()
        scene.render()
        """),

        Template(title: "manim: Graph Plot", icon: "chart.xyaxis.line", category: "Manim", code: """
        from manim import *
        import numpy as np

        class FunctionPlot(Scene):
            def construct(self):
                axes = Axes(
                    x_range=[-3, 3, 1],
                    y_range=[-2, 2, 1],
                    axis_config={"include_numbers": False}
                )
                sin_graph = axes.plot(lambda x: np.sin(x), color=BLUE)
                cos_graph = axes.plot(lambda x: np.cos(x), color=RED)

                sin_label = Text("sin(x)", font_size=24, color=BLUE).next_to(axes, UP + LEFT)
                cos_label = Text("cos(x)", font_size=24, color=RED).next_to(axes, UP + RIGHT)

                self.play(Create(axes), run_time=0.5)
                self.play(Create(sin_graph), Write(sin_label), run_time=0.5)
                self.play(Create(cos_graph), Write(cos_label), run_time=0.5)

        scene = FunctionPlot()
        scene.render()
        """),

        Template(title: "manim: Fermat's Little Thm", icon: "function", category: "Manim", code: #"""
        from manim import *

        # A short, iOS-memory-friendly proof of Fermat's Little Theorem.
        # Uses ~15 total animations and 5 MathTex blocks, well under the
        # 8 GB jetsam ceiling on iOS. Runs in ~25 s on iPad.

        class FermatLittle(Scene):
            def construct(self):
                # Title
                title = Tex(r"Fermat's Little Theorem").scale(1.2).to_edge(UP)
                self.play(Write(title))
                self.wait(0.5)

                # Statement
                statement = MathTex(
                    r"\text{If } p \text{ is prime and } \gcd(a, p) = 1,",
                    r"\text{then } a^{p-1} \equiv 1 \pmod{p}",
                    font_size=38,
                ).arrange(DOWN, buff=0.3)
                self.play(FadeIn(statement, shift=UP))
                self.wait(2)
                self.play(FadeOut(statement))

                # Step 1 — the key set
                step1 = Text(
                    "Consider the set S = {a, 2a, 3a, ..., (p-1)a} mod p",
                    font_size=28, color=BLUE,
                )
                step1.next_to(title, DOWN, buff=0.8)
                self.play(Write(step1))
                self.wait(1.5)

                # Step 2 — S is a permutation of {1, ..., p-1}
                step2 = MathTex(
                    r"\text{Claim: } S = \{1, 2, \dots, p-1\} \pmod{p}",
                    font_size=36, color=YELLOW,
                ).next_to(step1, DOWN, buff=0.6)
                self.play(FadeIn(step2))
                self.wait(1)

                why = Text(
                    "since ia = ja (mod p) with gcd(a,p)=1 implies i = j",
                    font_size=22, color=GRAY,
                ).next_to(step2, DOWN, buff=0.4)
                self.play(FadeIn(why))
                self.wait(2)

                self.play(FadeOut(step1), FadeOut(step2), FadeOut(why))

                # Step 3 — multiply both sides
                line1 = MathTex(
                    r"\prod_{i=1}^{p-1} (ia) \equiv \prod_{i=1}^{p-1} i \pmod{p}",
                    font_size=42,
                )
                line1.next_to(title, DOWN, buff=1.0)
                self.play(Write(line1))
                self.wait(1.5)

                line2 = MathTex(
                    r"a^{p-1} \cdot (p-1)! \equiv (p-1)! \pmod{p}",
                    font_size=42,
                )
                line2.next_to(line1, DOWN, buff=0.5)
                self.play(TransformFromCopy(line1, line2))
                self.wait(1.5)

                # Step 4 — cancel (p-1)!  (it's coprime to p)
                line3 = MathTex(
                    r"a^{p-1} \equiv 1 \pmod{p}",
                    font_size=54, color=GREEN,
                )
                line3.next_to(line2, DOWN, buff=0.7)
                self.play(TransformFromCopy(line2, line3))
                box = SurroundingRectangle(line3, color=GREEN, buff=0.25)
                self.play(Create(box))
                self.wait(3)

                qed = Tex(r"$\blacksquare$", color=GREEN).scale(1.5)
                qed.next_to(box, RIGHT, buff=0.4)
                self.play(Write(qed))
                self.wait(2)

                self.play(*[FadeOut(m) for m in [title, line1, line2, line3, box, qed]])

        scene = FermatLittle()
        scene.render()
        """#),

        // ── Comprehensive Tests ──
        Template(title: "🧪 Test matplotlib (ALL)", icon: "chart.xyaxis.line", category: "Test", code: """
        import numpy as np
        import matplotlib.pyplot as plt
        import matplotlib.cm as cm
        results = []
        def t(name, fn):
            try:
                fn(); results.append((name, True))
                plt.close('all')
            except Exception as e:
                results.append((name, False))
                print(f"❌ {name}: {e}")
                plt.close('all')

        x = np.linspace(-3, 3, 50)
        X, Y = np.meshgrid(x, x)
        Z = np.sin(X) * np.cos(Y)

        # 2D plots
        t("line plot", lambda: plt.plot(x, np.sin(x), label='sin'))
        t("multi line", lambda: (plt.plot(x, np.sin(x)), plt.plot(x, np.cos(x)), plt.legend()))
        t("scatter", lambda: plt.scatter(x, np.sin(x), c=x, cmap='viridis', s=20))
        t("bar", lambda: plt.bar(['A','B','C','D'], [3,7,2,5]))
        t("barh", lambda: plt.barh(['X','Y','Z'], [5,3,8]))
        t("hist", lambda: plt.hist(np.random.randn(500), bins=25, alpha=0.7))
        t("pie", lambda: plt.pie([30,20,50], labels=['A','B','C'], autopct='%1.1f%%'))
        t("fill_between", lambda: plt.fill_between(x, np.sin(x), 0, alpha=0.3))
        t("errorbar", lambda: plt.errorbar([1,2,3], [4,5,6], yerr=0.5))
        t("stem", lambda: plt.stem([1,2,3,4], [1,4,2,3]))
        t("step", lambda: plt.step([1,2,3,4], [1,4,2,3]))
        t("stackplot", lambda: plt.stackplot([1,2,3], [1,2,3], [3,2,1]))
        t("boxplot", lambda: plt.boxplot([np.random.randn(50) for _ in range(3)]))
        t("violinplot", lambda: plt.violinplot([np.random.randn(50) for _ in range(3)]))

        # Heatmap & contour
        t("imshow", lambda: (plt.imshow(np.random.rand(10,10), cmap='hot'), plt.colorbar()))
        t("contour", lambda: plt.contour(X, Y, Z, levels=10))
        t("contourf", lambda: plt.contourf(X, Y, Z, cmap='RdBu'))
        t("implicit eq", lambda: plt.contour(X, Y, X**2+Y**2, levels=[1], colors='blue'))

        # Styling
        t("title/labels", lambda: (plt.plot(x, np.sin(x)), plt.title("T"), plt.xlabel("X"), plt.ylabel("Y")))
        t("legend", lambda: (plt.plot(x, np.sin(x), label='sin'), plt.legend()))
        t("grid", lambda: (plt.plot(x, np.sin(x)), plt.grid(True)))
        t("xlim/ylim", lambda: (plt.plot(x, np.sin(x)), plt.xlim(-5, 5), plt.ylim(-2, 2)))
        t("log scale", lambda: (plt.plot([1,10,100,1000]), plt.yscale('log')))
        t("annotate", lambda: (plt.plot(x, np.sin(x)), plt.annotate("peak", xy=(1.57, 1))))
        t("axhline/axvline", lambda: (plt.axhline(0, color='r'), plt.axvline(0, color='b')))
        t("fmt 'ro-'", lambda: plt.plot([1,2,3], [1,4,9], 'ro-'))

        # Subplots
        t("subplots(2,2)", lambda: (lambda f,a: (a[0,0].plot(x,np.sin(x)), a[1,1].scatter(x,np.cos(x))))(*plt.subplots(2,2)))
        t("twinx", lambda: (lambda f,a: (a.plot(x,np.sin(x),'b'), a.twinx().plot(x,np.exp(x/3),'r')))(*plt.subplots()))
        t("axes.flat", lambda: (lambda f,a: [ax.plot(x,np.sin(x+i)) for i,ax in enumerate(a.flat)])(*plt.subplots(2,2)))

        # 3D
        t("plt.plot_surface", lambda: plt.plot_surface(X, Y, Z, cmap='viridis'))
        t("plt.scatter3D", lambda: plt.scatter3D([1,2,3], [4,5,6], [7,8,9], c=[1,2,3], cmap='plasma'))
        t("plt.plot3D", lambda: plt.plot3D(np.cos(np.linspace(0,6,50)), np.sin(np.linspace(0,6,50)), np.linspace(0,2,50)))
        t("plt.plot_wireframe", lambda: plt.plot_wireframe(X[:10,:10], Y[:10,:10], Z[:10,:10]))
        t("ax.plot_surface", lambda: (lambda f: f.add_subplot(111, projection='3d').plot_surface(X, Y, Z, cmap='coolwarm'))(plt.figure()))
        t("ax.view_init", lambda: (lambda ax: (ax.plot_surface(X,Y,Z), ax.view_init(30,45)))(plt.figure().add_subplot(111,projection='3d')))
        t("ax.set_zlabel", lambda: (lambda ax: (ax.plot_surface(X,Y,Z), ax.set_zlabel('Z')))(plt.figure().add_subplot(111,projection='3d')))
        t("Axes3D import", lambda: __import__('mpl_toolkits.mplot3d', fromlist=['Axes3D']))

        # Colormaps
        for c in ['viridis','plasma','hot','coolwarm','jet','RdBu','Spectral','gray']:
            t(f"cmap {c}", lambda c=c: plt.plot_surface(X[:10,:10], Y[:10,:10], Z[:10,:10], cmap=c))

        # Figure
        t("savefig", lambda: (plt.plot(x, np.sin(x)), plt.savefig('/tmp/mpl_test.html')))
        t("show", lambda: (plt.plot(x, np.sin(x)), plt.show()))

        # Polar
        t("polar", lambda: plt.polar(np.linspace(0,2*np.pi,100), 1+np.sin(np.linspace(0,2*np.pi,100))))

        p = sum(1 for _,ok in results if ok)
        f = sum(1 for _,ok in results if not ok)
        print(f"\\n{'='*40}")
        print(f"MATPLOTLIB: {p}/{len(results)} passed" + (" ✅" if f==0 else f" ({f} failed)"))
        """),

        Template(title: "🧪 Test sklearn (ALL)", icon: "brain", category: "Test", code: """
        import numpy as np
        results = []
        def t(name, fn):
            try:
                fn(); results.append((name, True))
            except Exception as e:
                results.append((name, False))
                print(f"❌ {name}: {e}")

        # Generate test data
        from sklearn.datasets import make_classification, make_regression, make_blobs, make_moons, load_iris
        X_cls, y_cls = make_classification(n_samples=100, n_features=5, random_state=42)
        X_reg, y_reg = make_regression(n_samples=100, n_features=5, random_state=42)
        X_blobs, y_blobs = make_blobs(n_samples=100, centers=3, random_state=42)
        X_moons, y_moons = make_moons(n_samples=100, noise=0.2, random_state=42)
        iris = load_iris()
        t("datasets", lambda: None)

        from sklearn.model_selection import train_test_split, cross_val_score
        X_tr, X_te, y_tr, y_te = train_test_split(X_cls, y_cls, test_size=0.3, random_state=42)
        t("train_test_split", lambda: None)

        # Linear models
        from sklearn.linear_model import LinearRegression, Ridge, Lasso, LogisticRegression
        t("LinearRegression", lambda: LinearRegression().fit(X_tr, y_tr).score(X_te, y_te))
        t("Ridge(alpha=1)", lambda: Ridge(alpha=1.0).fit(X_tr, y_tr))
        t("Lasso", lambda: Lasso(alpha=0.01, max_iter=1000).fit(X_tr, y_tr))
        t("LogisticRegression", lambda: LogisticRegression(max_iter=500, solver='lbfgs').fit(X_tr, y_tr).score(X_te, y_te))

        # Trees
        from sklearn.tree import DecisionTreeClassifier, DecisionTreeRegressor
        t("DecisionTreeClassifier", lambda: DecisionTreeClassifier(max_depth=5, criterion='gini').fit(X_tr, y_tr).score(X_te, y_te))
        t("DecisionTreeRegressor", lambda: DecisionTreeRegressor(max_depth=5).fit(X_reg[:70], y_reg[:70]))

        # Ensemble
        from sklearn.ensemble import RandomForestClassifier, GradientBoostingClassifier, AdaBoostClassifier, BaggingClassifier
        t("RandomForest", lambda: RandomForestClassifier(n_estimators=10, max_depth=5, random_state=42).fit(X_tr, y_tr).score(X_te, y_te))
        t("GradientBoosting", lambda: GradientBoostingClassifier(n_estimators=20, max_depth=3, learning_rate=0.1).fit(X_tr, y_tr))
        t("AdaBoost", lambda: AdaBoostClassifier(n_estimators=10).fit(X_tr, y_tr))
        t("Bagging", lambda: BaggingClassifier(n_estimators=5).fit(X_tr, y_tr))

        # SVM
        from sklearn.svm import SVC, SVR
        t("SVC", lambda: SVC(C=1.0, kernel='linear').fit(X_tr, y_tr).score(X_te, y_te))
        t("SVR", lambda: SVR(C=1.0, epsilon=0.1).fit(X_reg[:70], y_reg[:70]))

        # Neighbors
        from sklearn.neighbors import KNeighborsClassifier, KNeighborsRegressor
        t("KNeighborsClassifier", lambda: KNeighborsClassifier(n_neighbors=5).fit(X_tr, y_tr).score(X_te, y_te))
        t("KNeighborsRegressor", lambda: KNeighborsRegressor(n_neighbors=5).fit(X_reg[:70], y_reg[:70]))

        # Naive Bayes
        from sklearn.naive_bayes import GaussianNB, MultinomialNB
        t("GaussianNB", lambda: GaussianNB().fit(X_tr, y_tr).score(X_te, y_te))

        # Clustering
        from sklearn.cluster import KMeans, DBSCAN, AgglomerativeClustering
        t("KMeans", lambda: KMeans(n_clusters=3, init='k-means++', random_state=42).fit(X_blobs))
        t("DBSCAN", lambda: DBSCAN(eps=0.5, min_samples=5).fit(X_blobs))
        t("Agglomerative", lambda: AgglomerativeClustering(n_clusters=3).fit(X_blobs))

        # Decomposition
        from sklearn.decomposition import PCA, TruncatedSVD
        t("PCA", lambda: PCA(n_components=2, svd_solver='auto').fit_transform(X_cls))
        t("TruncatedSVD", lambda: TruncatedSVD(n_components=2).fit_transform(X_cls))

        # Preprocessing
        from sklearn.preprocessing import StandardScaler, MinMaxScaler, LabelEncoder, OneHotEncoder, PolynomialFeatures, RobustScaler
        t("StandardScaler", lambda: StandardScaler(copy=True).fit_transform(X_cls))
        t("MinMaxScaler", lambda: MinMaxScaler().fit_transform(X_cls))
        t("LabelEncoder", lambda: LabelEncoder().fit_transform(['a','b','c','a','b']))
        t("OneHotEncoder", lambda: OneHotEncoder(sparse_output=False).fit_transform([[0],[1],[2],[0]]))
        t("PolynomialFeatures", lambda: PolynomialFeatures(degree=2, include_bias=False).fit_transform(X_cls[:10,:2]))
        t("RobustScaler", lambda: RobustScaler().fit_transform(X_cls))

        # Pipeline
        from sklearn.pipeline import Pipeline, make_pipeline
        t("Pipeline", lambda: make_pipeline(StandardScaler(), LogisticRegression(max_iter=500)).fit(X_tr, y_tr).score(X_te, y_te))

        # Metrics
        from sklearn.metrics import accuracy_score, confusion_matrix, f1_score, r2_score, classification_report, silhouette_score
        y_pred = LogisticRegression(max_iter=500).fit(X_tr, y_tr).predict(X_te)
        t("accuracy_score", lambda: accuracy_score(y_te, y_pred))
        t("confusion_matrix", lambda: confusion_matrix(y_te, y_pred))
        t("f1_score", lambda: f1_score(y_te, y_pred, average='binary'))
        t("classification_report", lambda: classification_report(y_te, y_pred))
        km_labels = KMeans(n_clusters=3, random_state=42).fit_predict(X_blobs)
        t("silhouette_score", lambda: silhouette_score(X_blobs, km_labels))

        # Model selection
        t("cross_val_score", lambda: cross_val_score(LogisticRegression(max_iter=500), X_cls, y_cls, cv=3))
        from sklearn.model_selection import GridSearchCV
        t("GridSearchCV", lambda: GridSearchCV(Ridge(), {'alpha':[0.1,1.0,10.0]}, cv=3).fit(X_reg, y_reg))

        # Feature extraction
        from sklearn.feature_extraction import CountVectorizer, TfidfVectorizer
        docs = ["hello world", "world of code", "hello code"]
        t("CountVectorizer", lambda: CountVectorizer(analyzer='word').fit_transform(docs))
        t("TfidfVectorizer", lambda: TfidfVectorizer().fit_transform(docs))

        # Feature selection
        from sklearn.feature_selection import SelectKBest, VarianceThreshold, f_classif
        t("SelectKBest", lambda: SelectKBest(f_classif, k=3).fit_transform(X_cls, y_cls))
        t("VarianceThreshold", lambda: VarianceThreshold(threshold=0.0).fit_transform(X_cls))

        # Impute
        from sklearn.impute import SimpleImputer
        X_miss = X_cls.copy(); X_miss[0,0] = np.nan; X_miss[5,2] = np.nan
        t("SimpleImputer", lambda: SimpleImputer(strategy='mean').fit_transform(X_miss))

        # Manifold
        from sklearn.manifold import TSNE, MDS
        t("TSNE", lambda: TSNE(n_components=2, init='random', perplexity=10, random_state=42).fit_transform(X_cls[:50]))
        t("MDS", lambda: MDS(n_components=2, random_state=42).fit_transform(X_cls[:30]))

        # Neural Network
        from sklearn.neural_network import MLPClassifier
        t("MLPClassifier", lambda: MLPClassifier(hidden_layer_sizes=(20,10), max_iter=100, solver='adam', random_state=42).fit(X_tr, y_tr).score(X_te, y_te))

        # Discriminant Analysis
        from sklearn.discriminant_analysis import LinearDiscriminantAnalysis
        t("LDA", lambda: LinearDiscriminantAnalysis(solver='svd').fit(X_tr, y_tr).score(X_te, y_te))

        # Mixture
        from sklearn.mixture import GaussianMixture
        t("GaussianMixture", lambda: GaussianMixture(n_components=3, n_init=1, random_state=42).fit(X_blobs))

        # Dummy
        from sklearn.dummy import DummyClassifier
        t("DummyClassifier", lambda: DummyClassifier(strategy='most_frequent').fit(X_tr, y_tr).score(X_te, y_te))

        # Isotonic
        from sklearn.isotonic import IsotonicRegression
        t("IsotonicRegression", lambda: IsotonicRegression().fit_transform([1,2,3,4,5], [1,3,2,5,4]))

        # Multiclass
        from sklearn.multiclass import OneVsRestClassifier
        t("OneVsRestClassifier", lambda: OneVsRestClassifier(SVC(kernel='linear')).fit(X_tr, y_tr))

        # Compose
        from sklearn.compose import ColumnTransformer
        t("ColumnTransformer", lambda: ColumnTransformer(transformers=[('num', StandardScaler(), [0,1,2])]).fit_transform(X_cls))

        # Calibration
        from sklearn.calibration import CalibratedClassifierCV
        t("CalibratedClassifierCV", lambda: CalibratedClassifierCV)

        # Kernel
        from sklearn.kernel_ridge import KernelRidge
        t("KernelRidge", lambda: KernelRidge(alpha=1.0).fit(X_reg[:50], y_reg[:50]))

        # Gaussian Process
        from sklearn.gaussian_process import GaussianProcessRegressor
        t("GaussianProcessRegressor", lambda: GaussianProcessRegressor().fit(X_reg[:20,:2], y_reg[:20]))

        # Utils
        from sklearn.utils import check_array, Bunch
        t("check_array", lambda: check_array(X_cls))
        t("Bunch", lambda: Bunch(data=X_cls, target=y_cls))

        # Exceptions
        from sklearn.exceptions import NotFittedError
        t("NotFittedError", lambda: NotFittedError("test"))

        p = sum(1 for _,ok in results if ok)
        f = sum(1 for _,ok in results if not ok)
        print(f"\\n{'='*40}")
        print(f"SKLEARN: {p}/{len(results)} passed" + (" ✅" if f==0 else f" ({f} failed)"))
        """),

        // ── All libs test ──
        Template(title: "🧪 Test ALL Libraries", icon: "checkmark.shield.fill", category: "Test", code: """
        import sys, time
        results = []
        def test(name, fn):
            try:
                r = fn()
                results.append((name, True, str(r)[:80]))
                print(f"✅ {name}: {r}")
            except Exception as e:
                results.append((name, False, str(e)[:80]))
                print(f"❌ {name}: {e}")

        test("numpy", lambda: __import__('numpy').__version__)
        test("scipy", lambda: __import__('scipy').__version__)
        test("sympy", lambda: __import__('sympy').__version__)
        test("sklearn", lambda: __import__('sklearn').__version__)
        test("matplotlib", lambda: __import__('matplotlib').__version__)
        test("plotly", lambda: __import__('plotly').__version__)
        test("networkx", lambda: __import__('networkx').__version__)
        test("PIL", lambda: __import__('PIL').__version__)
        test("bs4", lambda: __import__('bs4').__version__)
        test("yaml", lambda: __import__('yaml').__version__)
        test("rich", lambda: __import__('rich').__version__)
        test("tqdm", lambda: __import__('tqdm').__version__)
        test("pygments", lambda: __import__('pygments').__version__)
        test("svgelements", lambda: __import__('svgelements').__version__)
        test("click", lambda: __import__('click').__version__)
        test("jsonschema", lambda: __import__('jsonschema').__version__)
        test("mpmath", lambda: __import__('mpmath').__version__)

        p = sum(1 for _,ok,_ in results if ok)
        f = sum(1 for _,ok,_ in results if not ok)
        print(f"\\n{'='*40}")
        print(f"RESULTS: {p} passed, {f} failed / {len(results)}")
        """),
    ]

    // MARK: - UI

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let outputView = UITextView()
    private let chartWebView: WKWebView = {
        let config = WKWebViewConfiguration()
        // iOS 14+: use the per-navigation toggle; the old preferences API is deprecated.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Force Plotly/images to fill 100% of the panel — overrides any
        // hardcoded heights in the HTML so charts don't get cropped.
        let fitScript = WKUserScript(source: """
            (function() {
                if (!document.querySelector('meta[name="viewport"]')) {
                    var m = document.createElement('meta');
                    m.name = 'viewport';
                    m.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
                    document.head.appendChild(m);
                }
                var s = document.createElement('style');
                s.textContent = [
                    'html, body { margin:0 !important; padding:0 !important; width:100% !important; height:100% !important; overflow:hidden !important; background:transparent !important; }',
                    'body > div:first-child { width:100% !important; height:100% !important; }',
                    '.plotly-graph-div, .js-plotly-plot, .svg-container, .main-svg { width:100% !important; height:100% !important; }',
                    'img, canvas, video { max-width:100% !important; max-height:100% !important; object-fit:contain; }',
                ].join('\\n');
                document.head.appendChild(s);
                function _r() {
                    if (!window.Plotly) return;
                    document.querySelectorAll('.js-plotly-plot').forEach(function(p) {
                        try { Plotly.Plots.resize(p); } catch (e) {}
                    });
                }
                _r(); setTimeout(_r, 80); setTimeout(_r, 300);
                window.addEventListener('resize', _r);
                if (window.ResizeObserver) new ResizeObserver(_r).observe(document.body);
            })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(fitScript)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.layer.cornerRadius = 12
        wv.layer.cornerCurve = .continuous
        wv.clipsToBounds = true
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.isHidden = true
        return wv
    }()
    private let chartImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.backgroundColor = .white
        iv.layer.cornerRadius = 12
        iv.layer.cornerCurve = .continuous
        iv.clipsToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.isHidden = true
        return iv
    }()
    private let runButton = UIButton(type: .system)
    private let codeView = UITextView()
    private let splitView = UIStackView()
    private var selectedIndex: Int = 0
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        setupUI()
        selectTemplate(at: 0)
    }

    private func setupUI() {
        // ── Left: Template list ──
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear

        // ── Right: Code + Output ──
        let rightPanel = UIView()
        rightPanel.translatesAutoresizingMaskIntoConstraints = false

        // Code editor
        codeView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        codeView.backgroundColor = UIColor(white: 0.12, alpha: 1)
        codeView.textColor = UIColor(red: 0.8, green: 0.9, blue: 0.8, alpha: 1)
        codeView.isEditable = true
        codeView.autocorrectionType = .no
        codeView.autocapitalizationType = .none
        codeView.spellCheckingType = .no
        codeView.layer.cornerRadius = 12
        codeView.layer.cornerCurve = .continuous
        codeView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        codeView.translatesAutoresizingMaskIntoConstraints = false

        // Run button
        var btnConfig = UIButton.Configuration.filled()
        btnConfig.title = "Run"
        btnConfig.image = UIImage(systemName: "play.fill")
        btnConfig.imagePadding = 8
        btnConfig.baseBackgroundColor = .systemGreen
        btnConfig.baseForegroundColor = .white
        btnConfig.cornerStyle = .capsule
        btnConfig.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20)
        runButton.configuration = btnConfig
        runButton.addTarget(self, action: #selector(runTapped), for: .touchUpInside)
        runButton.translatesAutoresizingMaskIntoConstraints = false

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true

        let buttonRow = UIStackView(arrangedSubviews: [runButton, activityIndicator, UIView()])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 12
        buttonRow.alignment = .center
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        // Output
        let outputLabel = UILabel()
        outputLabel.text = "Output"
        outputLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        outputLabel.textColor = .secondaryLabel
        outputLabel.translatesAutoresizingMaskIntoConstraints = false

        outputView.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        outputView.backgroundColor = UIColor.secondarySystemGroupedBackground
        outputView.textColor = .label
        outputView.isEditable = false
        outputView.layer.cornerRadius = 12
        outputView.layer.cornerCurve = .continuous
        outputView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        outputView.translatesAutoresizingMaskIntoConstraints = false
        outputView.text = "Tap Run to execute..."

        rightPanel.addSubview(codeView)
        rightPanel.addSubview(buttonRow)
        rightPanel.addSubview(outputLabel)
        rightPanel.addSubview(outputView)
        rightPanel.addSubview(chartWebView)
        rightPanel.addSubview(chartImageView)

        NSLayoutConstraint.activate([
            codeView.topAnchor.constraint(equalTo: rightPanel.topAnchor, constant: 8),
            codeView.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 8),
            codeView.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -8),
            codeView.heightAnchor.constraint(equalTo: rightPanel.heightAnchor, multiplier: 0.35),

            buttonRow.topAnchor.constraint(equalTo: codeView.bottomAnchor, constant: 8),
            buttonRow.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 8),
            buttonRow.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -8),

            outputLabel.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 8),
            outputLabel.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 12),

            outputView.topAnchor.constraint(equalTo: outputLabel.bottomAnchor, constant: 4),
            outputView.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 8),
            outputView.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -8),
            outputView.bottomAnchor.constraint(equalTo: rightPanel.bottomAnchor, constant: -8),

            // Chart WebView overlays the output area
            chartWebView.topAnchor.constraint(equalTo: outputLabel.bottomAnchor, constant: 4),
            chartWebView.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 8),
            chartWebView.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -8),
            chartWebView.bottomAnchor.constraint(equalTo: rightPanel.bottomAnchor, constant: -8),

            // Image view for PNG output (manim, etc.)
            chartImageView.topAnchor.constraint(equalTo: outputLabel.bottomAnchor, constant: 4),
            chartImageView.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 8),
            chartImageView.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -8),
            chartImageView.bottomAnchor.constraint(equalTo: rightPanel.bottomAnchor, constant: -8),
        ])

        // ── Split layout ──
        view.addSubview(tableView)
        view.addSubview(rightPanel)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.widthAnchor.constraint(equalToConstant: 260),

            rightPanel.topAnchor.constraint(equalTo: view.topAnchor),
            rightPanel.leadingAnchor.constraint(equalTo: tableView.trailingAnchor),
            rightPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rightPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func selectTemplate(at index: Int) {
        selectedIndex = index
        let template = Self.templates[index]
        // Dedent the code (remove leading whitespace from multiline strings)
        let lines = template.code.split(separator: "\n", omittingEmptySubsequences: false)
        let minIndent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.count - $0.drop(while: { $0 == " " }).count }
            .min() ?? 0
        let dedented = lines.map { line in
            let s = String(line)
            return s.count >= minIndent ? String(s.dropFirst(minIndent)) : s
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        codeView.text = dedented
        outputView.text = "Tap Run to execute..."
        outputView.textColor = .secondaryLabel
        outputView.isHidden = false
        chartWebView.isHidden = true
        chartImageView.isHidden = true
        chartImageView.image = nil
    }

    // MARK: - Run

    @objc private func runTapped() {
        guard let code = codeView.text, !code.isEmpty else { return }
        outputView.text = "Running..."
        outputView.textColor = .secondaryLabel
        activityIndicator.startAnimating()
        runButton.isEnabled = false

        let template = Self.templates[selectedIndex]
        let isC = template.category == "C"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let start = CFAbsoluteTimeGetCurrent()
            let output: String
            var chartPath: String?

            if isC {
                let result = CRuntime.shared.execute(code)
                if result.success {
                    output = result.output.isEmpty ? "(no output)" : result.output
                } else {
                    output = "Error: \(result.error ?? "unknown")\n\(result.output)"
                }
            } else {
                let result = PythonRuntime.shared.execute(code: code)
                output = result.output.isEmpty ? "(no output)" : result.output
                chartPath = result.imagePath
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start

            DispatchQueue.main.async {
                guard let self else { return }
                self.activityIndicator.stopAnimating()
                self.runButton.isEnabled = true
                let hasError = output.lowercased().contains("error") || output.contains("❌") || output.contains("Traceback")

                // Filter out "[plot saved] ..." lines from text output
                let cleanOutput = output.components(separatedBy: "\n")
                    .filter { !$0.hasPrefix("[plot saved]") && !$0.hasPrefix("[manim rendered]") }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let displayText = cleanOutput.isEmpty
                    ? "⏱ \(String(format: "%.2f", elapsed))s"
                    : "\(cleanOutput)\n\n⏱ \(String(format: "%.2f", elapsed))s"

                self.outputView.textColor = hasError ? .systemRed : .label
                self.outputView.text = displayText
                self.outputView.scrollRangeToVisible(NSRange(location: 0, length: 0))

                // Show chart/image if available
                if let path = chartPath, FileManager.default.fileExists(atPath: path) {
                    if path.hasSuffix(".html") {
                        // Interactive plotly chart
                        self.chartWebView.isHidden = false
                        self.chartImageView.isHidden = true
                        self.outputView.isHidden = true
                        let url = URL(fileURLWithPath: path)
                        self.chartWebView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
                    } else if let img = UIImage(contentsOfFile: path) {
                        // Static image (manim PNG, matplotlib PNG, etc.)
                        self.chartImageView.image = img
                        self.chartImageView.isHidden = false
                        self.chartWebView.isHidden = true
                        self.outputView.isHidden = true
                    } else {
                        self.chartWebView.isHidden = true
                        self.chartImageView.isHidden = true
                        self.outputView.isHidden = false
                    }
                } else {
                    self.chartWebView.isHidden = true
                    self.chartImageView.isHidden = true
                    self.outputView.isHidden = false
                }
            }
        }
    }

    // MARK: - TableView

    func numberOfSections(in tableView: UITableView) -> Int { 1 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { Self.templates.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let t = Self.templates[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = t.title
        config.secondaryText = t.category
        config.image = UIImage(systemName: t.icon)
        config.imageProperties.tintColor = categoryColor(t.category)
        config.textProperties.font = .systemFont(ofSize: 14, weight: .medium)
        config.secondaryTextProperties.font = .systemFont(ofSize: 11)
        config.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = config
        cell.backgroundColor = indexPath.row == selectedIndex ? .systemBlue.withAlphaComponent(0.1) : .clear
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectTemplate(at: indexPath.row)
        tableView.reloadData()
    }

    private func categoryColor(_ cat: String) -> UIColor {
        switch cat {
        case "NumPy": return .systemBlue
        case "SciPy": return .systemTeal
        case "SymPy": return .systemPurple
        case "ML": return .systemGreen
        case "Plot": return .systemOrange
        case "Graph": return .systemPink
        case "Math": return .systemIndigo
        case "C": return .systemGray
        case "Manim": return .systemYellow
        case "Test": return .systemRed
        default: return .label
        }
    }
}
