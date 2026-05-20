import UIKit
import WebKit
import PDFKit
import SwiftTerm
import GameController  // magic-keyboard detection
import UniformTypeIdentifiers  // UTType for the toolbar "Open" picker

extension Notification.Name {
    /// Posted by `CodeEditorViewController` after the editor's auto-save
    /// successfully writes to disk. The notification's `object` is the
    /// `URL` of the saved file. Listeners (e.g. the file browser) can
    /// reload immediately rather than waiting for kqueue's debounce.
    static let editorDidSaveFile = Notification.Name("CodeBench.editorDidSaveFile")

    /// Posted by `FilesBrowserViewController` after a file or folder
    /// is permanently deleted from disk. The notification's `object`
    /// is the deleted `URL`. The editor listens for this so it can
    /// drop its `currentFileURL` if the user just deleted the file
    /// they had open — without this, the next auto-save would write
    /// the buffer back out and resurrect the file the user just told
    /// us to delete.
    static let fileDidDelete = Notification.Name("CodeBench.fileDidDelete")

    /// Posted by `SceneDelegate` when iOS hands us a file via "Open With…"
    /// (Files app, Share Sheet, drag-and-drop). The notification's
    /// `object` is the imported `URL` (already inside our Documents/
    /// directory — see SceneDelegate.handleIncomingURL for the security-
    /// scoped copy logic). The editor listens for this so it can call
    /// loadFile(url:) on whichever editor instance is foreground.
    static let openExternalFile = Notification.Name("CodeBench.openExternalFile")

    /// Posted by `PywebviewBridge` when WKWebView's separate WebContent
    /// process is terminated by the system (memory pressure while the
    /// app is backgrounded — common when the user slides to another
    /// app and comes back). The `object` is the affected ``WKWebView``.
    /// The editor listens for this so it can re-issue ``showImageOutput``
    /// for the last-shown chart/HTML, recovering the preview without
    /// the user having to re-run the script. Without this, the WebView
    /// silently shows a blank/dark page after every app-switch round
    /// trip — the rendered chart appears to "reset".
    static let previewWebContentDied =
        Notification.Name("CodeBench.previewWebContentDied")
}

// MARK: - CodeEditorViewController

/// Monaco-style split-view code editor with AI chat sidebar and terminal output.
final class CodeEditorViewController: UIViewController {

    // MARK: - Types

    enum Language: Int, CaseIterable {
        case python = 0
        case c = 1
        case cpp = 2
        case fortran = 3
        case latex = 4
        case swift = 5

        var title: String {
            switch self {
            case .python: return "Python"
            case .c: return "C"
            case .cpp: return "C++"
            case .fortran: return "Fortran"
            case .latex: return "LaTeX"
            case .swift: return "Swift"
            }
        }

        /// Monaco language identifier.
        var monacoName: String {
            switch self {
            case .python: return "python"
            case .c: return "c"
            case .cpp: return "cpp"
            case .fortran: return "fortran" // Tokenizer is registered by editor.js
            case .latex: return "latex"     // Monaco has builtin latex tokenizer
            case .swift: return "swift"     // Monaco has builtin swift tokenizer
            }
        }

        var defaultCode: String {
            switch self {
            case .python:
                return "# Python playground\nimport math\n\ndef greet(name):\n    return f\"Hello, {name}!\"\n\nprint(greet(\"World\"))\nprint(f\"pi = {math.pi:.6f}\")\n"
            case .c:
                return "#include <stdio.h>\n#include <math.h>\n\nint main() {\n    printf(\"Hello, World!\\n\");\n    printf(\"pi = %.6f\\n\", M_PI);\n    return 0;\n}\n"
            case .cpp:
                return "#include <iostream>\n#include <vector>\n#include <string>\nusing namespace std;\n\nclass Greeter {\npublic:\n    string name;\n    Greeter(string n) { name = n; }\n    void greet() { cout << \"Hello, \" << name << \"!\" << endl; }\n};\n\nint main() {\n    Greeter g(\"World\");\n    g.greet();\n\n    vector<int> nums = {1, 2, 3, 4, 5};\n    for (auto& n : nums) {\n        cout << n * n << \" \";\n    }\n    cout << endl;\n    return 0;\n}\n"
            case .fortran:
                return "program hello\n    implicit none\n    integer :: i\n    real :: pi\n    pi = 4.0 * atan(1.0)\n    print *, \"Hello, World!\"\n    print *, \"pi =\", pi\n    do i = 1, 5\n        print *, \"i =\", i, \"i^2 =\", i*i\n    end do\nend program hello\n"
            case .latex:
                return "\\documentclass{article}\n\\usepackage{amsmath, amssymb}\n\n\\title{Hello, \\LaTeX{}}\n\\author{CodeBench}\n\n\\begin{document}\n\\maketitle\n\nThis is a sample LaTeX document.\n\n\\section{Math}\n\\begin{equation}\n  e^{i\\pi} + 1 = 0\n\\end{equation}\n\n\\end{document}\n"
            case .swift:
                return "// Swift playground (tree-walking interpreter — no JIT)\nimport Foundation\n\nfunc greet(_ name: String) -> String {\n    return \"Hello, \\(name)!\"\n}\n\nprint(greet(\"World\"))\n\nlet nums = [1, 2, 3, 4, 5]\nlet squares = nums.map { $0 * $0 }\nprint(\"squares = \\(squares)\")\n\nlet total = nums.reduce(0) { $0 + $1 }\nprint(\"sum = \\(total)\")\n"
            }
        }
    }

    // MARK: - Template

    struct Template {
        let title: String
        let icon: String
        let category: String
        let language: Language
        let code: String
    }

    static let templates: [Template] = [
        // ── manim ──

        Template(title: "manim: Basic Shapes", icon: "sparkles", category: "Manim", language: .python, code:
        "from manim import *\n\nclass BasicShapes(Scene):\n  def construct(self):\n    circle = Circle(radius=0.6, color=BLUE, fill_opacity=0.6)\n    square = Square(side_length=1.0, color=RED, fill_opacity=0.5)\n    triangle = Triangle(color=GREEN, fill_opacity=0.5).scale(0.6)\n    star = Star(n=5, outer_radius=0.6, color=GOLD, fill_opacity=0.6)\n    dot = Dot(radius=0.2, color=WHITE)\n    arrow = Arrow(LEFT*0.5, RIGHT*0.5, color=YELLOW)\n    line = Line(LEFT*0.5, RIGHT*0.5, color=PURPLE, stroke_width=4)\n    row1 = VGroup(circle, square, triangle, star).arrange(RIGHT, buff=0.8)\n    row2 = VGroup(dot, arrow, line).arrange(RIGHT, buff=1.2)\n    grid = VGroup(row1, row2).arrange(DOWN, buff=1.0)\n    self.play(LaggedStart(*[Create(m) for m in [circle, square, triangle, star, dot, arrow, line]], lag_ratio=0.2), run_time=3)\n    self.wait(0.5)\n\nscene = BasicShapes()\nscene.render()\n"),

        Template(title: "manim: Transformations", icon: "arrow.triangle.2.circlepath", category: "Manim", language: .python, code:
        "from manim import *\n\nclass Transformations(Scene):\n  def construct(self):\n    circle = Circle(color=BLUE, fill_opacity=0.8)\n    square = Square(color=RED, fill_opacity=0.8)\n    triangle = Triangle(color=GREEN, fill_opacity=0.8)\n    star = Star(color=GOLD, fill_opacity=0.8)\n    self.play(Create(circle))\n    self.play(Transform(circle, square))\n    self.play(ReplacementTransform(circle, triangle))\n    self.play(FadeOut(triangle))\n    self.play(FadeIn(star))\n    self.play(Rotate(star, angle=PI), run_time=1)\n    self.play(star.animate.scale(0.3))\n    self.play(star.animate.scale(3))\n    self.play(FadeOut(star))\n    self.wait(0.5)\n\nscene = Transformations()\nscene.render()\n"),

        Template(title: "manim: Function Graphs", icon: "chart.xyaxis.line", category: "Manim", language: .python, code:
        "from manim import *\nimport numpy as np\n\nclass FunctionGraphs(Scene):\n  def construct(self):\n    axes = Axes(x_range=[-4, 4, 1], y_range=[-2, 4, 1], x_length=10, y_length=6, axis_config={'include_numbers': False})\n    sin_curve = axes.plot(lambda x: np.sin(x), color=BLUE, x_range=[-4, 4])\n    cos_curve = axes.plot(lambda x: np.cos(x), color=RED, x_range=[-4, 4])\n    para_curve = axes.plot(lambda x: 0.25*x**2, color=GREEN, x_range=[-3.5, 3.5])\n    self.play(Create(axes), run_time=1)\n    self.play(Create(sin_curve), run_time=1)\n    self.play(Create(cos_curve), run_time=1)\n    self.play(Create(para_curve), run_time=1)\n    area = axes.get_area(sin_curve, x_range=[0, PI], color=BLUE, opacity=0.3)\n    self.play(FadeIn(area))\n    self.wait(0.5)\n\nscene = FunctionGraphs()\nscene.render()\n"),

        Template(title: "manim: Animated Plot", icon: "point.topleft.down.to.point.bottomright.curvepath", category: "Manim", language: .python, code:
        "from manim import *\nimport numpy as np\n\nclass AnimatedPlot(Scene):\n  def construct(self):\n    axes = Axes(x_range=[-4, 4, 1], y_range=[-2, 2, 1], x_length=10, y_length=5, axis_config={'include_numbers': False})\n    curve = axes.plot(lambda x: np.sin(x), color=BLUE)\n    self.play(Create(axes), Create(curve), run_time=1)\n    tracker = ValueTracker(-4)\n    dot = Dot(color=YELLOW, radius=0.12)\n    dot.add_updater(lambda d: d.move_to(axes.c2p(tracker.get_value(), np.sin(tracker.get_value()))))\n    trail = TracedPath(dot.get_center, stroke_color=YELLOW, stroke_width=3)\n    self.add(trail, dot)\n    self.play(tracker.animate.set_value(4), run_time=4, rate_func=linear)\n    self.wait(0.5)\n\nscene = AnimatedPlot()\nscene.render()\n"),

        Template(title: "manim: 3D Surface", icon: "cube", category: "Manim", language: .python, code:
        "from manim import *\nimport numpy as np\n\nclass ThreeDSurface(ThreeDScene):\n  def construct(self):\n    axes = ThreeDAxes(x_range=[-3, 3], y_range=[-3, 3], z_range=[-2, 2])\n    surface = Surface(lambda u, v: axes.c2p(u, v, np.sin(u) * np.cos(v)), u_range=[-3, 3], v_range=[-3, 3], resolution=(30, 30))\n    surface.set_style(fill_opacity=0.7)\n    surface.set_fill_by_value(axes=axes, colorscale=[(RED, -1), (YELLOW, 0), (GREEN, 1)])\n    self.set_camera_orientation(phi=70*DEGREES, theta=30*DEGREES)\n    self.play(Create(axes), Create(surface), run_time=2)\n    self.begin_ambient_camera_rotation(rate=0.3)\n    self.wait(3)\n    self.stop_ambient_camera_rotation()\n    self.wait(0.5)\n\nscene = ThreeDSurface()\nscene.render()\n"),

        Template(title: "manim: Color Gradient", icon: "paintbrush", category: "Manim", language: .python, code:
        "from manim import *\nimport numpy as np\n\nclass ColorGradient(Scene):\n  def construct(self):\n    colors = [RED, RED_A, ORANGE, YELLOW, YELLOW_A, GREEN, GREEN_A, TEAL, TEAL_A, BLUE, BLUE_A, PURPLE, PURPLE_A, PINK, MAROON, GOLD]\n    dots = VGroup()\n    n = len(colors)\n    for i, c in enumerate(colors):\n      angle = i * TAU / n\n      dot = Dot(radius=0.25, color=c, fill_opacity=0.9)\n      dot.move_to(2.5 * np.array([np.cos(angle), np.sin(angle), 0]))\n      dots.add(dot)\n    inner = VGroup()\n    for i, c in enumerate(colors):\n      angle = i * TAU / n + TAU / (2*n)\n      dot = Dot(radius=0.15, color=c, fill_opacity=0.6)\n      dot.move_to(1.5 * np.array([np.cos(angle), np.sin(angle), 0]))\n      inner.add(dot)\n    self.play(LaggedStart(*[FadeIn(d, scale=0.5) for d in dots], lag_ratio=0.08), run_time=2)\n    self.play(LaggedStart(*[FadeIn(d, scale=0.5) for d in inner], lag_ratio=0.08), run_time=1.5)\n    self.play(Rotate(dots, angle=TAU, run_time=2, rate_func=smooth))\n    self.wait(0.5)\n\nscene = ColorGradient()\nscene.render()\n"),

        Template(title: "manim: Geometry Proof", icon: "triangle", category: "Manim", language: .python, code:
        "from manim import *\nimport numpy as np\n\nclass GeometryProof(Scene):\n  def construct(self):\n    a = np.array([-2, -1, 0])\n    b = np.array([1, -1, 0])\n    c = np.array([-2, 2, 0])\n    tri = Polygon(a, b, c, color=WHITE, stroke_width=3)\n    right_angle = Square(side_length=0.3, color=WHITE, stroke_width=2).move_to(a + np.array([0.15, 0.15, 0]))\n    ab = np.linalg.norm(b - a)\n    bc = np.linalg.norm(c - b)\n    ca = np.linalg.norm(a - c)\n    sq_a = Square(side_length=ab, color=RED, fill_opacity=0.3, stroke_width=2)\n    sq_a.next_to(Line(a, b), DOWN, buff=0)\n    sq_b = Square(side_length=ca, color=GREEN, fill_opacity=0.3, stroke_width=2)\n    sq_b.next_to(Line(a, c), LEFT, buff=0)\n    sq_c_side = bc\n    mid_bc = (b + c) / 2\n    direction = np.array([c[1] - b[1], b[0] - c[0], 0])\n    direction = direction / np.linalg.norm(direction)\n    sq_c = Square(side_length=sq_c_side, color=BLUE, fill_opacity=0.3, stroke_width=2)\n    sq_c.move_to(mid_bc + direction * sq_c_side / 2)\n    sq_c.rotate(np.arctan2(c[1]-b[1], c[0]-b[0]))\n    self.play(Create(tri), Create(right_angle), run_time=1)\n    self.play(FadeIn(sq_a), run_time=0.8)\n    self.play(FadeIn(sq_b), run_time=0.8)\n    self.play(FadeIn(sq_c), run_time=0.8)\n    self.play(Indicate(sq_a), Indicate(sq_b), run_time=1)\n    self.play(Indicate(sq_c), run_time=1)\n    self.wait(0.5)\n\nscene = GeometryProof()\nscene.render()\n"),

        Template(title: "manim: Number Line", icon: "ruler", category: "Manim", language: .python, code:
        "from manim import *\n\nclass NumberLineDemo(Scene):\n  def construct(self):\n    nline = NumberLine(x_range=[-5, 5, 1], length=10, include_numbers=False, include_tip=True)\n    ticks = VGroup(*[Dot(radius=0.06, color=YELLOW).move_to(nline.n2p(i)) for i in range(-5, 6)])\n    self.play(Create(nline), run_time=1)\n    self.play(LaggedStart(*[FadeIn(t, scale=0.5) for t in ticks], lag_ratio=0.1))\n    arrow = Arrow(start=UP*0.8, end=DOWN*0.1, color=RED, buff=0).move_to(nline.n2p(-4) + UP*0.5)\n    self.play(GrowArrow(arrow))\n    tracker = ValueTracker(-4)\n    arrow.add_updater(lambda a: a.move_to(nline.n2p(tracker.get_value()) + UP*0.5))\n    self.play(tracker.animate.set_value(4), run_time=3, rate_func=smooth)\n    self.play(tracker.animate.set_value(0), run_time=1.5)\n    self.wait(0.5)\n\nscene = NumberLineDemo()\nscene.render()\n"),

        Template(title: "manim: Matrix Transform", icon: "grid", category: "Manim", language: .python, code:
        "from manim import *\nimport numpy as np\n\nclass MatrixTransform(Scene):\n  def construct(self):\n    plane = NumberPlane(x_range=[-5, 5], y_range=[-4, 4], background_line_style={'stroke_color': BLUE_D, 'stroke_opacity': 0.3})\n    basis_i = Arrow(plane.c2p(0, 0), plane.c2p(1, 0), buff=0, color=GREEN, stroke_width=5)\n    basis_j = Arrow(plane.c2p(0, 0), plane.c2p(0, 1), buff=0, color=RED, stroke_width=5)\n    dot = Dot(plane.c2p(1, 1), color=YELLOW, radius=0.1)\n    self.play(Create(plane), GrowArrow(basis_i), GrowArrow(basis_j), FadeIn(dot), run_time=1.5)\n    matrix = [[2, 1], [0, 1.5]]\n    self.play(plane.animate.apply_matrix(matrix), basis_i.animate.put_start_and_end_on(plane.c2p(0, 0), plane.c2p(2, 0)), basis_j.animate.put_start_and_end_on(plane.c2p(0, 0), plane.c2p(1, 1.5)), dot.animate.move_to(plane.c2p(3, 1.5)), run_time=2)\n    self.wait(0.5)\n\nscene = MatrixTransform()\nscene.render()\n"),

        Template(title: "manim: Bar Chart", icon: "chart.bar", category: "Manim", language: .python, code:
        "from manim import *\n\nclass BarChartDemo(Scene):\n  def construct(self):\n    chart = BarChart(values=[3, 5, 2, 8, 4, 7], bar_names=['A', 'B', 'C', 'D', 'E', 'F'], bar_colors=[BLUE, RED, GREEN, YELLOW, PURPLE, ORANGE], y_range=[0, 10, 2], y_length=4, x_length=9)\n    self.play(Create(chart), run_time=2)\n    self.play(chart.animate.change_bar_values([7, 3, 9, 2, 6, 4]), run_time=1.5)\n    self.play(chart.animate.change_bar_values([5, 5, 5, 5, 5, 5]), run_time=1.5)\n    self.play(chart.animate.change_bar_values([1, 4, 9, 4, 1, 6]), run_time=1.5)\n    self.wait(0.5)\n\nscene = BarChartDemo()\nscene.render()\n"),

        Template(title: "manim: Vector Field", icon: "wind", category: "Manim", language: .python, code:
        "from manim import *\nimport numpy as np\n\nclass VectorFieldDemo(Scene):\n  def construct(self):\n    func = lambda p: np.array([-p[1], p[0], 0]) * 0.3\n    field = ArrowVectorField(func, x_range=[-4, 4, 0.8], y_range=[-3, 3, 0.8], colors=[BLUE, GREEN, YELLOW, RED])\n    self.play(Create(field), run_time=2)\n    dot = Dot(color=WHITE, radius=0.12).move_to(RIGHT*2 + UP)\n    self.play(FadeIn(dot))\n    stream = StreamLines(func, x_range=[-4, 4], y_range=[-3, 3], stroke_width=2, max_anchors_per_line=30)\n    self.play(FadeOut(field), run_time=0.5)\n    self.add(stream)\n    stream.start_animation(warm_up=True, flow_speed=1.5)\n    self.wait(3)\n    self.wait(0.5)\n\nscene = VectorFieldDemo()\nscene.render()\n"),

        Template(title: "manim: Fractal (Sierpinski)", icon: "triangle.inset.filled", category: "Manim", language: .python, code:
        "from manim import *\nimport numpy as np\n\nclass Sierpinski(Scene):\n  def construct(self):\n    def make_triangles(vertices, depth):\n      if depth == 0:\n        return [Polygon(*vertices, color=BLUE, fill_opacity=0.7, stroke_width=1)]\n      a, b, c = vertices\n      ab = (a + b) / 2\n      bc = (b + c) / 2\n      ca = (c + a) / 2\n      t1 = make_triangles([a, ab, ca], depth - 1)\n      t2 = make_triangles([ab, b, bc], depth - 1)\n      t3 = make_triangles([ca, bc, c], depth - 1)\n      return t1 + t2 + t3\n    v0 = np.array([-3.5, -2.5, 0])\n    v1 = np.array([3.5, -2.5, 0])\n    v2 = np.array([0, 3.0, 0])\n    colors = [BLUE, GREEN, YELLOW, RED, PURPLE]\n    prev = None\n    for d in range(5):\n      tris = make_triangles([v0, v1, v2], d)\n      col = colors[d % len(colors)]\n      for t in tris:\n        t.set_fill(col, opacity=0.6)\n        t.set_stroke(col, width=1)\n      group = VGroup(*tris)\n      if prev is None:\n        self.play(Create(group), run_time=1)\n      else:\n        self.play(ReplacementTransform(prev, group), run_time=1)\n      prev = group\n    self.wait(0.5)\n\nscene = Sierpinski()\nscene.render()\n"),

        Template(title: "manim: Pendulum", icon: "metronome", category: "Manim", language: .python, code:
        "from manim import *\nimport numpy as np\n\nclass PendulumScene(Scene):\n  def construct(self):\n    pivot = Dot(UP*3, color=WHITE, radius=0.08)\n    length = 3.0\n    tracker = ValueTracker(PI/4)\n    bob = Dot(color=RED, radius=0.2)\n    rod = Line(start=UP*3, end=UP*3, color=GREY, stroke_width=3)\n    def update_bob(b):\n      angle = tracker.get_value()\n      pos = pivot.get_center() + length * np.array([np.sin(angle), -np.cos(angle), 0])\n      b.move_to(pos)\n    def update_rod(r):\n      r.put_start_and_end_on(pivot.get_center(), bob.get_center())\n    bob.add_updater(update_bob)\n    rod.add_updater(update_rod)\n    trail = TracedPath(bob.get_center, stroke_color=YELLOW, stroke_width=2, stroke_opacity=0.5)\n    self.add(pivot, rod, bob, trail)\n    update_bob(bob)\n    update_rod(rod)\n    for i in range(6):\n      amp = PI/4 * (0.85 ** i)\n      self.play(tracker.animate.set_value(-amp), run_time=0.7, rate_func=smooth)\n      self.play(tracker.animate.set_value(amp), run_time=0.7, rate_func=smooth)\n    self.play(tracker.animate.set_value(0), run_time=0.5)\n    self.wait(0.5)\n\nscene = PendulumScene()\nscene.render()\n"),

        Template(title: "manim: Wave Animation", icon: "wave.3.right", category: "Manim", language: .python, code:
        "from manim import *\nimport numpy as np\n\nclass WaveAnimation(Scene):\n  def construct(self):\n    axes = Axes(x_range=[0, 10, 1], y_range=[-2, 2, 1], x_length=12, y_length=4, axis_config={'include_numbers': False})\n    self.play(Create(axes), run_time=0.5)\n    tracker = ValueTracker(0)\n    wave = always_redraw(lambda: axes.plot(lambda x: np.sin(2*x - tracker.get_value()), color=BLUE, x_range=[0, 10]))\n    wave2 = always_redraw(lambda: axes.plot(lambda x: 0.5 * np.sin(4*x - 2*tracker.get_value()), color=RED, x_range=[0, 10]))\n    combined = always_redraw(lambda: axes.plot(lambda x: np.sin(2*x - tracker.get_value()) + 0.5*np.sin(4*x - 2*tracker.get_value()), color=GREEN, x_range=[0, 10]))\n    self.play(Create(wave), run_time=0.5)\n    self.play(Create(wave2), run_time=0.5)\n    self.play(Create(combined), run_time=0.5)\n    self.play(tracker.animate.set_value(4*PI), run_time=5, rate_func=linear)\n    self.wait(0.5)\n\nscene = WaveAnimation()\nscene.render()\n"),

        // ── Text rendering tests ──

        Template(title: "Test: Simple Text", icon: "textformat.abc", category: "Test", language: .python, code:
        "from manim import *\n\nclass SimpleText(Scene):\n  def construct(self):\n    t1 = Text('Hello World', font_size=72)\n    self.play(Write(t1), run_time=2)\n    self.wait(1)\n    t2 = Text('Manim on iPad', font_size=48, color=YELLOW)\n    t2.next_to(t1, DOWN, buff=0.5)\n    self.play(FadeIn(t2))\n    self.wait(0.5)\n\nscene = SimpleText()\nscene.render()\n"),

        Template(title: "Test: Colored Text", icon: "paintpalette", category: "Test", language: .python, code:
        "from manim import *\n\nclass ColoredText(Scene):\n  def construct(self):\n    colors = [RED, ORANGE, YELLOW, GREEN, BLUE, PURPLE]\n    names = ['Red', 'Orange', 'Yellow', 'Green', 'Blue', 'Purple']\n    group = VGroup()\n    for c, n in zip(colors, names):\n      t = Text(n, font_size=36, color=c)\n      group.add(t)\n    group.arrange(DOWN, buff=0.3)\n    self.play(LaggedStart(*[Write(t) for t in group], lag_ratio=0.3), run_time=3)\n    self.wait(0.5)\n\nscene = ColoredText()\nscene.render()\n"),

        Template(title: "Test: Text + Shapes", icon: "text.below.photo", category: "Test", language: .python, code:
        "from manim import *\n\nclass TextAndShapes(Scene):\n  def construct(self):\n    title = Text('Geometry', font_size=48, color=WHITE)\n    title.to_edge(UP)\n    self.play(Write(title))\n    circle = Circle(radius=1, color=BLUE, fill_opacity=0.5)\n    label_c = Text('Circle', font_size=24, color=BLUE)\n    label_c.next_to(circle, DOWN)\n    square = Square(side_length=1.5, color=RED, fill_opacity=0.5)\n    label_s = Text('Square', font_size=24, color=RED)\n    label_s.next_to(square, DOWN)\n    group = VGroup(VGroup(circle, label_c), VGroup(square, label_s)).arrange(RIGHT, buff=2)\n    self.play(Create(circle), Create(square), run_time=1)\n    self.play(Write(label_c), Write(label_s))\n    self.wait(0.5)\n\nscene = TextAndShapes()\nscene.render()\n"),

        Template(title: "Test: MathTex", icon: "function", category: "Test", language: .python, code:
        "from manim import *\n\nclass MathTest(Scene):\n  def construct(self):\n    eq1 = MathTex('E = mc^2', font_size=60)\n    eq2 = MathTex('a^2 + b^2 = c^2', font_size=48)\n    eq3 = MathTex('\\\\int_0^1 x^2 dx = \\\\frac{1}{3}', font_size=48)\n    group = VGroup(eq1, eq2, eq3).arrange(DOWN, buff=0.6)\n    self.play(Write(eq1), run_time=1.5)\n    self.play(Write(eq2), run_time=1.5)\n    self.play(Write(eq3), run_time=1.5)\n    self.wait(0.5)\n\nscene = MathTest()\nscene.render()\n"),

        Template(title: "Test: Text Transform", icon: "arrow.triangle.2.circlepath", category: "Test", language: .python, code:
        "from manim import *\n\nclass TextTransform(Scene):\n  def construct(self):\n    t1 = Text('Transform', font_size=60, color=BLUE)\n    t2 = Text('Animation', font_size=60, color=RED)\n    t3 = Text('Complete!', font_size=60, color=GREEN)\n    self.play(Write(t1))\n    self.play(Transform(t1, t2))\n    self.play(Transform(t1, t3))\n    self.wait(0.5)\n\nscene = TextTransform()\nscene.render()\n"),

        Template(title: "Test: Axes with Labels", icon: "chart.xyaxis.line", category: "Test", language: .python, code:
        "from manim import *\nimport numpy as np\n\nclass AxesLabels(Scene):\n  def construct(self):\n    axes = Axes(x_range=[-3, 3, 1], y_range=[-2, 2, 1], x_length=8, y_length=5, axis_config={'include_numbers': True})\n    x_label = Text('x', font_size=24).next_to(axes.x_axis, RIGHT)\n    y_label = Text('y', font_size=24).next_to(axes.y_axis, UP)\n    title = Text('sin(x) and cos(x)', font_size=32).to_edge(UP)\n    sin_curve = axes.plot(lambda x: np.sin(x), color=BLUE)\n    cos_curve = axes.plot(lambda x: np.cos(x), color=RED)\n    sin_label = Text('sin', font_size=20, color=BLUE).next_to(axes, UR)\n    cos_label = Text('cos', font_size=20, color=RED).next_to(sin_label, DOWN, aligned_edge=LEFT)\n    self.play(Write(title), Create(axes), Write(x_label), Write(y_label), run_time=1)\n    self.play(Create(sin_curve), Write(sin_label), run_time=1)\n    self.play(Create(cos_curve), Write(cos_label), run_time=1)\n    self.wait(0.5)\n\nscene = AxesLabels()\nscene.render()\n"),

    ]

    // MARK: - Theme Colors

    /// High-tech dark theme — refined VS Code Dark+ with better contrast
    private enum EditorTheme {
        // Deep dark palette (mirrors Monaco's offlinai-dark theme in editor.html)
        static let background    = UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1.0) // #0a0a0f — deep black-blue
        static let foreground    = UIColor(red: 0.941, green: 0.941, blue: 0.961, alpha: 1.0) // #f0f0f5
        // Syntax — violet/amber/emerald accents
        static let keyword       = UIColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 1.0) // #8b5cf6 — violet
        static let string        = UIColor(red: 0.984, green: 0.749, blue: 0.141, alpha: 1.0) // #fbbf24 — amber
        static let comment       = UIColor(red: 0.420, green: 0.420, blue: 0.502, alpha: 1.0) // #6b6b80
        static let number        = UIColor(red: 0.204, green: 0.827, blue: 0.600, alpha: 1.0) // #34d399 — emerald
        // Gutter / elevated bg
        static let gutterBg      = UIColor(red: 0.071, green: 0.071, blue: 0.102, alpha: 1.0) // #12121a
        static let gutterText    = UIColor(red: 0.314, green: 0.314, blue: 0.408, alpha: 1.0) // #505068
        // Terminal
        static let terminalBg      = UIColor(red: 0.020, green: 0.024, blue: 0.032, alpha: 1.0) // #05060a — deeper so ANSI colors pop
        static let terminalText    = UIColor(red: 0.863, green: 0.878, blue: 0.910, alpha: 1.0) // #dce0e8 — brighter default
        static let terminalMuted   = UIColor(red: 0.420, green: 0.435, blue: 0.482, alpha: 1.0) // #6b6f7b — muted info lines ($…)
        static let terminalError   = UIColor(red: 1.000, green: 0.392, blue: 0.392, alpha: 1.0) // #ff6464
        static let terminalSuccess = UIColor(red: 0.400, green: 0.867, blue: 0.490, alpha: 1.0) // #66dd7d
        static let terminalPrompt  = UIColor(red: 0.467, green: 0.729, blue: 1.000, alpha: 1.0) // #77baff — $ prompt
        // AI Chat — slightly elevated
        static let chatBg        = UIColor(red: 0.102, green: 0.102, blue: 0.157, alpha: 1.0) // #1a1a28
        static let userBubble    = UIColor(red: 0.169, green: 0.169, blue: 0.259, alpha: 1.0) // #2b2b42
        static let aiBubble      = UIColor(red: 0.122, green: 0.122, blue: 0.180, alpha: 1.0) // #1f1f2e
        // Accents
        static let accent        = UIColor(red: 0.388, green: 0.400, blue: 0.945, alpha: 1.0) // #6366f1 — indigo
        static let accentViolet  = UIColor(red: 0.659, green: 0.333, blue: 0.969, alpha: 1.0) // #a855f7
        static let borderSub     = UIColor(red: 0.388, green: 0.400, blue: 0.945, alpha: 0.15) // faint indigo
    }

    // MARK: - Syntax Keywords

    private static let pythonKeywords: Set<String> = [
        "def", "class", "if", "elif", "else", "for", "while", "return", "import",
        "from", "as", "in", "not", "and", "or", "try", "except", "with", "lambda",
        "print", "True", "False", "None", "raise", "finally", "yield", "pass",
        "break", "continue", "del", "global", "nonlocal", "assert", "is"
    ]

    private static let cKeywords: Set<String> = [
        "int", "float", "double", "char", "void", "if", "else", "for", "while",
        "do", "return", "struct", "enum", "typedef", "printf", "malloc", "free",
        "sizeof", "static", "const", "unsigned", "long", "short", "switch", "case",
        "break", "continue", "default", "NULL", "auto", "register", "extern", "union"
    ]

    private static let cppKeywords: Set<String> = [
        // C base
        "int", "float", "double", "char", "void", "if", "else", "for", "while",
        "do", "return", "struct", "enum", "typedef", "sizeof", "static", "const",
        "unsigned", "long", "short", "switch", "case", "break", "continue", "default",
        // C++ specific
        "class", "public", "private", "protected", "new", "delete", "this", "virtual",
        "override", "namespace", "using", "template", "typename", "auto", "bool",
        "true", "false", "nullptr", "try", "catch", "throw", "operator", "friend",
        "inline", "explicit", "mutable", "constexpr", "final", "noexcept",
        // STL
        "cout", "cin", "endl", "string", "vector", "map", "pair", "tuple",
        "sort", "find", "count", "reverse", "begin", "end", "push_back", "size",
        "make_pair", "include", "iostream", "algorithm"
    ]

    private static let fortranKeywords: Set<String> = [
        "program", "end", "implicit", "none", "integer", "real", "character",
        "logical", "complex", "double", "precision", "print", "write", "read",
        "if", "then", "else", "elseif", "endif", "do", "while", "enddo",
        "call", "subroutine", "function", "module", "use", "contains", "result",
        "allocate", "deallocate", "allocatable", "dimension", "intent",
        "type", "select", "case", "exit", "cycle", "return", "stop",
        "parameter", "save", "data"
    ]

    // Python builtins + popular library symbols for autocomplete
    private static let pythonBuiltins: [String] = [
        // builtins
        "print", "len", "range", "list", "dict", "tuple", "set", "str", "int", "float",
        "bool", "None", "True", "False", "input", "open", "map", "filter", "sorted",
        "enumerate", "zip", "reversed", "min", "max", "sum", "abs", "round", "type",
        "isinstance", "hasattr", "getattr", "setattr", "iter", "next", "any", "all",
        "format", "repr", "id", "hash", "super", "property", "staticmethod", "classmethod",
        // numpy
        "np.array", "np.zeros", "np.ones", "np.arange", "np.linspace", "np.random",
        "np.mean", "np.std", "np.var", "np.sum", "np.min", "np.max", "np.dot",
        "np.sqrt", "np.sin", "np.cos", "np.tan", "np.exp", "np.log", "np.pi",
        "np.reshape", "np.concatenate", "np.transpose", "np.where", "np.argmax",
        // manim
        "Scene", "Text", "MathTex", "Tex", "Circle", "Square", "Rectangle", "Triangle",
        "Line", "Arrow", "VGroup", "Dot", "NumberPlane", "Axes", "FadeIn", "FadeOut",
        "Write", "Create", "Transform", "DrawBorderThenFill", "ShowCreation", "ReplacementTransform",
        "UP", "DOWN", "LEFT", "RIGHT", "ORIGIN", "YELLOW", "BLUE", "RED", "GREEN", "WHITE",
        "BLACK", "PURPLE", "ORANGE", "PINK", "GRAY", "self.play", "self.wait", "self.add",
        "self.camera", "to_edge", "next_to", "arrange", "shift", "scale", "rotate",
        // scipy
        "scipy.optimize", "scipy.integrate", "scipy.signal", "scipy.stats", "scipy.linalg",
        "minimize", "curve_fit", "solve_ivp", "quad", "fft", "ifft",
        // matplotlib
        "plt.plot", "plt.scatter", "plt.bar", "plt.hist", "plt.title", "plt.xlabel",
        "plt.ylabel", "plt.legend", "plt.show", "plt.figure", "plt.subplot", "plt.savefig",
        // sympy
        "symbols", "integrate", "diff", "solve", "limit", "series", "simplify", "expand",
        "factor", "Symbol", "Rational", "oo", "sin", "cos", "tan", "sqrt", "exp", "log",
        // requests
        "requests.get", "requests.post", "requests.put", "requests.delete", "requests.Session",
        // common imports
        "import numpy as np", "import matplotlib.pyplot as plt", "from manim import *",
        "import scipy", "import sympy", "import pandas as pd", "import requests",
    ]

    private static let cBuiltins: [String] = [
        "printf", "scanf", "malloc", "free", "calloc", "realloc", "memcpy", "memset",
        "strlen", "strcpy", "strcmp", "strcat", "fopen", "fclose", "fread", "fwrite",
        "fprintf", "fscanf", "sprintf", "sscanf", "stdin", "stdout", "stderr",
        "NULL", "EOF", "#include <stdio.h>", "#include <stdlib.h>", "#include <string.h>",
        "#include <math.h>", "int main(void)", "int main(int argc, char *argv[])",
    ]

    private static let cppBuiltins: [String] = [
        "std::cout", "std::cin", "std::endl", "std::string", "std::vector",
        "std::map", "std::unordered_map", "std::pair", "std::make_pair", "std::tuple",
        "std::sort", "std::find", "std::count", "std::reverse", "std::swap",
        "std::unique_ptr", "std::shared_ptr", "std::make_shared", "std::make_unique",
        "std::thread", "std::mutex", "std::function", "std::ranges",
        "#include <iostream>", "#include <vector>", "#include <string>", "#include <map>",
        "#include <algorithm>", "int main()", "using namespace std;",
    ]

    private static let fortranBuiltins: [String] = [
        "print *,", "write(*,*)", "read(*,*)", "call exit", "sqrt", "sin", "cos", "tan",
        "exp", "log", "abs", "mod", "real", "int", "nint", "floor", "ceiling",
        "program main", "end program", "subroutine", "end subroutine",
        "function", "end function", "module", "end module",
    ]

    // Swift keywords recognised by the in-house tree-walking interpreter
    // (SwiftInterpreter.swift). Limited to tier-2 surface: declarations,
    // control flow, optionals. We intentionally omit symbols the runtime
    // cannot evaluate (e.g. `actor`, `async`, `throws`) so autocomplete
    // doesn't suggest constructs that will fail at run-time.
    private static let swiftKeywords: Set<String> = [
        "let", "var", "func", "return", "if", "else", "guard", "while", "repeat",
        "for", "in", "switch", "case", "default", "break", "continue", "do",
        "true", "false", "nil", "self", "where", "as", "is",
        "Int", "Double", "String", "Bool", "Array", "Dictionary", "Optional",
        "Void", "Any", "AnyObject",
    ]

    private static let swiftBuiltins: [String] = [
        "print", "abs", "min", "max", "sqrt", "pow",
        "Int", "Double", "String", "Bool",
        ".count", ".isEmpty", ".append", ".first", ".last", ".map", ".filter",
        ".reduce", ".sorted", ".reversed", ".contains", ".removeLast", ".removeFirst",
        ".uppercased", ".lowercased", ".hasPrefix", ".hasSuffix", ".split", ".trimmed",
        ".keys", ".values",
        "if let", "guard let", "?? ", "func main()",
    ]

    // MARK: - Properties

    private var currentLanguage: Language = .python
    private var chatMessages: [(role: String, text: String)] = []
    // AI chat panel starts HIDDEN — the user explicitly toggles it on via the
    // "AI Assist" pill in the editor header bar.
    private var isAIChatVisible = false
    // isSettingsPanelVisible removed — settings now shown as popover
    /// Assigned externally by GameViewController when embedding
    var llamaRunner: LlamaRunner?
    /// Called when the user picks a model from the model selector menu
    var onModelSelected: ((ModelSlot) -> Void)?

    // MARK: - UI Components

    // Toolbar
    private let toolbar = UIView()
    private let languageControl = UISegmentedControl(items: ["Python", "C", "C++", "Fortran", "LaTeX", "Swift"])  // hidden, kept for internal state — indices must match Language enum raw values
    private let runButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let openFileButton = UIButton(type: .system)
    /// Toolbar toggle for the embedded file panel — folder icon that
    /// collapses (width → 0) or expands (width → 220pt) the files
    /// browser pinned to the left of the editor.
    private let filesToggleButton = UIButton(type: .system)
    private let templatesButton = UIButton(type: .system)  // unused but kept for compile compat
    private let aiToggleButton = UIButton(type: .system)
    private let latexTestButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let docsButton = UIButton(type: .system)

    // Editor
    private let editorContainer = UIView()
    // Files panel mounted inside the editor's leftPanel (replaces the
    // file browser that used to live in the app sidebar). Collapsible
    // via the toolbar's folder icon — width 220pt when shown, 0 when
    // hidden. The FilesBrowserViewController child still owns its own
    // navigation state.
    private let editorFilesPanel = UIView()
    private var editorFilesWidthConstraint: NSLayoutConstraint!
    private var editorFilesPanelVisible: Bool = true
    /// The child FilesBrowserViewController hosted inside editorFilesPanel.
    /// Different instance from `GameViewController.filesBrowserController`
    /// (which is now nil after the sidebar slim-down).
    private weak var editorFilesBrowserController: FilesBrowserViewController?
    private let editorHeaderBar = UIView()
    private let editorFileNameLabel = UILabel()
    // Faint path breadcrumb on the right side of the editor header.
    // Reads as "Workspace / parent / src" — a quiet locator hint.
    // Added during the Claude Design merge to balance the header bar
    // (file pill on the leading edge was previously paired with empty
    // space on the trailing edge).
    private let breadcrumbLabel = UILabel()
    // Tasteful "AI Assist" chip sitting on the header's trailing edge.
    // Violet capsule + plus icon — invites the user into the in-app
    // AI chat without competing visually with Run.
    private let aiAssistChip = UIButton(type: .system)
    // Always-on RAM sparkline pinned between the breadcrumb and the
    // AI Assist chip. Polls phys_footprint vs jetsam limit every
    // 1.5s; tap to bring up the breakdown sheet. Same widget Game-
    // ViewController uses on the chat home screen.
    private let editorMemoryGraph = MemoryGraphView()
    // Per-language SF Symbol icon for the active file tab. Swapped on
    // load (see iconSymbol(for:)) so a .swift file gets the Swift mark,
    // .py gets a chevron-bracket icon, etc.
    private let fileIconView = UIImageView()
    // Small filled circle that appears to the right of the filename
    // when the buffer has unsaved changes — the familiar "modified"
    // indicator from VS Code / Xcode. Updated via updateModifiedDot().
    private let modifiedDot = UIView()
    // Language pill on the right of the header. Shows the current
    // Language.title in a colour-tinted capsule (no toggle, just an
    // unambiguous label so the tab itself doesn't have to spell it out).
    private let langPill = UILabel()
    // 1.5pt accent bar pinned to the TOP edge of the file pill. Makes
    // the pill look like an active editor tab — same visual idiom as
    // VS Code's active-tab indicator. Recolored when the language changes.
    private let tabTopAccent = UIView()

    /// VS Code–style thin status bar pinned to the bottom of the
    /// editor pane. Shows file name, detected language, cursor
    /// position (line/column), encoding, and a colored status dot
    /// that mirrors the "ready / running / error" terminal state.
    /// Tap any segment for context-relevant actions (cursor → jump
    /// to line, language → open Manim settings, etc.).
    private let editorStatusBar = UIView()
    private let statusFileLabel = UILabel()
    private let statusLanguageLabel = UILabel()
    private let statusCursorLabel = UILabel()
    private let statusEncodingLabel = UILabel()
    private let statusStateDot = UIView()
    private let statusStateLabel = UILabel()

    // Monaco editor (WebView-hosted, replaces UITextView + custom autocomplete UI)
    private let monacoView = MonacoEditorView()

    // Legacy orphan stubs — kept to preserve compile of dead-code paths that Monaco replaces.
    // These UIViews are NEVER added to the view hierarchy; Monaco handles all their roles.
    private let gutterView = UIView()
    private let lineNumberLabel = UILabel()
    private let suggestionsTable = UITableView(frame: .zero, style: .plain)
    private var currentSuggestions: [CompletionItem] = []
    private var suggestionTriggerRange: NSRange?
    private var suggestionsHidden: Bool = true
    private var suggestionDebouncer: DispatchWorkItem?
    private var currentMatchPrefix: String = ""
    private let docPreviewPanel = UIView()
    private let docPreviewSignatureLabel = UILabel()
    private let docPreviewTextView = UITextView()
    private var docPreviewVisible = false
    private let signatureTooltip = UIView()
    private let signatureTooltipLabel = UILabel()
    private var signatureTooltipVisible = false
    private let codeTextView = UITextView()

    // AI Chat (below code editor in left panel)
    private let aiChatContainer = UIView()
    private let chatTitleLabel = UILabel()
    private let modelSelectorButton = UIButton(type: .system)
    private let chatScrollView = UIScrollView()
    private let chatStackView = UIStackView()
    private let chatInputField = UITextField()
    private let chatSendButton = UIButton(type: .system)
    private var aiChatWidthConstraint: NSLayoutConstraint!

    // Output panel (right side)
    private let outputPanel = UIView()
    // Output panel header (matches editorHeaderBar's 36pt baseline).
    // Roll-your-own pill toggle (per design CSS .ed-seg) instead of
    // UISegmentedControl — the design wants inset indigo bg on active
    // segments which UISegmentedControl can't replicate cleanly.
    private let outputHeaderBar = UIView()
    private let outputTitleLabel = UILabel()
    private let outputTabsContainer = UIView()
    private let outputTabConsole = UIButton(type: .system)
    private let outputTabPreview = UIButton(type: .system)
    private let outputTabPlots = UIButton(type: .system)
    private var outputTabsSelectedIndex: Int = 0
    // Play-circle + grid overlay + meta footer for the empty-state body.
    private let outputPlaymark = UIView()
    private let outputPlaymarkIcon = UIImageView()
    private let outputMetaLabel = UILabel()
    private weak var outputPlaceholderGridLayer: CALayer?
    private let outputWebView: WKWebView = {
        let config = WKWebViewConfiguration()
        // iOS 14+: per-navigation JS toggle on WKWebpagePreferences. The
        // older `preferences.javaScriptEnabled` is deprecated.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Inject viewport + responsive CSS — but ONLY apply the
        // fit-to-pane rules when the page looks like a chart (Plotly,
        // Bokeh-style div) or a single-image artefact. For real
        // interactive HTML/CSS/JS apps the user opens from the
        // workspace, leave their layout alone so scrolling, custom
        // layouts, modal overlays, etc. all work as the author
        // intended.
        let viewportScript = WKUserScript(source: """
            (function() {
                if (!document.querySelector('meta[name="viewport"]')) {
                    var m = document.createElement('meta');
                    m.name = 'viewport';
                    m.content = 'width=device-width, initial-scale=1.0';
                    document.head.appendChild(m);
                }
                // Detection: chart-fit mode kicks in only for pages
                // that already contain Plotly/Bokeh/Vega style markers,
                // OR pages where the body's only child is a single
                // <img>/<video>/<canvas> (the "view this artefact"
                // shape). Everything else gets normal scrolling +
                // no clamping so React/Vue/vanilla apps render natively.
                var hasChart = !!document.querySelector(
                    '.plotly-graph-div,.js-plotly-plot,.svg-container,.main-svg,' +
                    '.bk-root,.vega-embed,canvas.chartjs-render-monitor');
                var bodyKids = document.body ? document.body.children : [];
                var soloMedia = bodyKids.length === 1 &&
                    /^(IMG|VIDEO|CANVAS)$/.test(bodyKids[0].tagName);
                var fitMode = hasChart || soloMedia;

                var style = document.createElement('style');
                if (fitMode) {
                    style.textContent = [
                        'html, body { margin:0 !important; padding:0 !important; width:100% !important; height:100% !important; overflow:hidden !important; background:transparent !important; }',
                        'body > div:first-child { width:100% !important; height:100% !important; }',
                        '.plotly-graph-div, .js-plotly-plot, .svg-container, .main-svg { width:100% !important; height:100% !important; }',
                        'img, canvas { max-width:100% !important; max-height:100% !important; object-fit:contain; }',
                        'video { max-width:100% !important; max-height:100% !important; object-fit:contain; }',
                    ].join('\\n');
                } else {
                    // Interactive-page mode: minimal CSS — just stop
                    // iOS Safari from auto-zooming on text inputs and
                    // make sure the body isn't 0 height (some authors
                    // forget html,body{height:100%}).
                    style.textContent = [
                        'html { -webkit-text-size-adjust: 100%; }',
                        'body { min-height: 100vh; }',
                    ].join('\\n');
                }
                document.head.appendChild(style);

                // Force Plotly to re-measure after layout settles.
                function _resizePlotly() {
                    if (!window.Plotly) return;
                    var plots = document.querySelectorAll('.js-plotly-plot');
                    plots.forEach(function(p) {
                        try { Plotly.Plots.resize(p); } catch (e) {}
                    });
                }
                if (fitMode) {
                    _resizePlotly();
                    setTimeout(_resizePlotly, 60);
                    setTimeout(_resizePlotly, 200);
                    setTimeout(_resizePlotly, 500);
                    window.addEventListener('resize', _resizePlotly);
                    if (window.ResizeObserver) {
                        var ro = new ResizeObserver(_resizePlotly);
                        ro.observe(document.body);
                    }
                }
            })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(viewportScript)
        // Clipboard polyfill — WKWebView's `navigator.clipboard.writeText`
        // silently no-ops in non-https contexts and inside iframes, which
        // breaks every "Copy" button on pages loaded into the preview
        // pane. Install a polyfill at document-start that routes
        // writeText through a Swift message handler, which copies to
        // UIPasteboard.general (the system clipboard). Also intercept
        // `document.execCommand('copy')` for older pages — we read the
        // current selection's text and forward it the same way. Pages
        // that already have native clipboard access still work; we
        // overwrite the global anyway so behaviour is deterministic.
        let clipboardScript = WKUserScript(source: """
            (function() {
              function _send(text) {
                try {
                  window.webkit.messageHandlers.clipboard.postMessage(
                    String(text == null ? '' : text));
                } catch (e) {}
              }
              // navigator.clipboard.writeText shim — always resolves.
              var clip = navigator.clipboard || {};
              clip.writeText = function(text) {
                _send(text);
                return Promise.resolve();
              };
              // Provide a stub readText so feature-detection passes.
              if (!clip.readText) {
                clip.readText = function() { return Promise.resolve(''); };
              }
              try { navigator.clipboard = clip; } catch (e) {}
              // Intercept document.execCommand('copy'/'cut') — read the
              // current selection and forward it. Returns true so JS
              // that branches on the result continues happily.
              var _orig = document.execCommand
                ? document.execCommand.bind(document) : null;
              document.execCommand = function(cmd) {
                if (cmd === 'copy' || cmd === 'cut') {
                  var sel = window.getSelection
                    ? String(window.getSelection()) : '';
                  // Fallback: if there's no selection, look for a
                  // focused <input>/<textarea> selection.
                  if (!sel) {
                    var el = document.activeElement;
                    if (el && ('value' in el)) {
                      var s = el.selectionStart, e = el.selectionEnd;
                      if (typeof s === 'number' && typeof e === 'number'
                          && s !== e) {
                        sel = String(el.value).slice(s, e);
                      } else {
                        sel = String(el.value || '');
                      }
                    }
                  }
                  _send(sel);
                  return true;
                }
                return _orig ? _orig.apply(document, arguments) : false;
              };
            })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(clipboardScript)
        // Install the pywebview JS↔Python bridge: WKScriptMessageHandler
        // for "pywebview" messages plus the document-start bootstrap that
        // exposes window.pywebview.api as a Proxy. Pages that don't use
        // pywebview pay nothing — the bootstrap just sets up an unused
        // global. See CodeBench/PywebviewBridge.swift.
        PywebviewBridge.configure(config)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        // Scroll enabled so interactive web apps (workspace HTML/CSS/JS)
        // can pan when content exceeds the pane. Chart-only pages keep
        // body{overflow:hidden} via the injected CSS, so they fit-to-pane
        // even with this on — the scrollView just becomes a passthrough.
        wv.scrollView.isScrollEnabled = true
        wv.layer.cornerRadius = 8
        wv.clipsToBounds = true
        wv.translatesAutoresizingMaskIntoConstraints = false
        return wv
    }()
    private let outputImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.backgroundColor = .black
        iv.layer.cornerRadius = 8
        iv.clipsToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.isHidden = true
        return iv
    }()
    /// Dedicated PDF viewer — WKWebView's built-in PDF rendering ignores
    /// our `scrollView.isScrollEnabled = true` and the injected viewport
    /// CSS (`overflow:hidden !important`) clamps it to one page. PDFKit's
    /// PDFView is native, handles multi-page scrolling / pinch-zoom /
    /// text-selection / page nav out of the box.
    private let outputPDFView: PDFView = {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.pageBreakMargins = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        v.backgroundColor = UIColor(white: 0.10, alpha: 1.0)
        v.layer.cornerRadius = 8
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()
    private let outputPlaceholderLabel: UILabel = {
        let l = UILabel()
        // Design CSS .ed-empty: 13pt color #5e5e72. No leading ▶ glyph
        // — the play-circle (outputPlaymark) sits to the left of this
        // label instead, matching the mockup's .ed-playmark layout.
        l.text = "Run code to see output"
        l.textColor = UIColor(red: 0x5e/255.0, green: 0x5e/255.0, blue: 0x72/255.0, alpha: 1.0)
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textAlignment = .left
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // Terminal (SwiftTerm xterm emulator attached to PTY)
    private let terminalContainer = UIView()
    private let terminalTitleBar = UIView()
    private let terminalTitleLabel = UILabel()
    private let terminalStatusDot = UIView()
    private let terminalStatusLabel = UILabel()
    private let terminalSpinner = UIActivityIndicatorView(style: .medium)
    private let terminalClearButton = UIButton(type: .system)
    // Claude Design slim-strip terminal title components. Replace the
    // legacy Mac-Terminal traffic lights + centered title with a single
    // 26pt informational row: [● dot] interpreter-lab · zsh · 80×24 · 1 session  …  [path] [⌄]
    private let termWorkspaceDot       = UIView()
    private let termWorkspaceNameLabel = UILabel()
    private let termMetaLabel          = UILabel()
    private let termSessionsLabel      = UILabel()
    private let termPathPill           = UILabel()
    private let termCollapseChevron    = UIButton(type: .system)
    /// Real xterm emulator from the SwiftTerm SPM package. Python's
    /// stdin/stdout/stderr are dup2'd onto a PTY (via PTYBridge.setupIfNeeded)
    /// so every print, every rich.Console, every pip progress bar shows
    /// up here with correct color + cursor positioning.
    let swiftTermView: SwiftTerm.TerminalView = {
        let tv = SwiftTerm.TerminalView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()
    private var terminalHeightConstraint: NSLayoutConstraint!
    private let terminalDragHandle = UIView()
    private let terminalCopyButton = UIButton(type: .system)
    /// ANSI-parse state carried across streaming chunks — without this,
    /// a color set mid-line and emitted in one chunk would reset to
    /// default in the next chunk and lose continuity.
    private var terminalANSIState = ANSI.State()

    // Interactive terminal input (cd, ls, python foo.py, pip install, etc.)
    private let terminalInputBar = UIView()
    private let terminalPromptLabel = UILabel()
    private let terminalInputField = TerminalInputField()
    private let terminalSendButton = UIButton(type: .system)
    private var terminalHistory: [String] = []
    private var terminalHistoryIndex: Int = 0
    private var terminalShellReady: Bool = false
    private var terminalContinuation: Bool = false  // ps2 state

    // Mac-style window controls (traffic lights + extras)
    private enum TerminalWindowState { case normal, minimized, maximized }
    private var terminalWindowState: TerminalWindowState = .normal
    private var terminalNormalHeight: CGFloat = 200
    /// Shadow plaintext buffer that mirrors whatever we feed into SwiftTerm.
    /// SwiftTerm doesn't expose scrollback as a String, so we remember what
    /// we've pushed so Copy / Export-log can still work.
    private var terminalLogBuffer = String()
    private let terminalTrafficClose = UIButton(type: .system)
    private let terminalTrafficMin   = UIButton(type: .system)
    private let terminalTrafficMax   = UIButton(type: .system)
    private let terminalInterruptButton = UIButton(type: .system)
    private let terminalFontMinusButton = UIButton(type: .system)
    private let terminalFontPlusButton  = UIButton(type: .system)
    private let terminalMenuButton      = UIButton(type: .system)
    private let terminalBottomResizeHandle = UIView()
    private var terminalFontSize: CGFloat = 13

    enum TerminalStatus {
        case ready, running, success, failure
        var title: String {
            switch self {
            case .ready:   return "ready"
            case .running: return "running"
            case .success: return "done"
            case .failure: return "failed"
            }
        }
        var color: UIColor {
            switch self {
            case .ready:   return UIColor(white: 0.55, alpha: 1)
            case .running: return UIColor(red: 0.4, green: 0.7, blue: 1, alpha: 1)
            case .success: return UIColor(red: 0.4, green: 0.87, blue: 0.49, alpha: 1)
            case .failure: return UIColor(red: 1, green: 0.39, blue: 0.39, alpha: 1)
            }
        }
    }

    // Settings — created fresh in popover each time (no persistent controls)

    // Layout
    private let leftPanel = UIView()
    private let topStack = UIStackView()
    private let mainStack = UIStackView()
    private var outputPanelWidthConstraint: NSLayoutConstraint!
    /// Invisible 6pt-wide grab handle overlapping the editor↔output
    /// divider. User can pan it to resize the output panel; on iPad
    /// the system cursor turns into a horizontal-resize chevron when
    /// hovering over it.
    private let outputDragHandle = UIView()
    /// Width pin captured at the start of a drag so each delta is
    /// computed against the panel's pre-drag size, not the moving
    /// target.
    private var outputPanelDragStartWidth: CGFloat = 521
    /// UserDefaults key for the persisted custom output-panel width.
    private static let kOutputPanelWidthKey = "CodeBench.outputPanelWidth"

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = EditorTheme.background
        // Pick up the user's last terminal-size choice from the Settings
        // tab so first paint matches the persisted preference. Falls
        // back to the default 13pt if Settings is unset.
        terminalFontSize = CGFloat(Settings.terminalFontSize)
        setupToolbar()
        setupEditor()
        setupAIChat()
        setupOutputPanel()
        setupTerminal()
        setupSettingsPanel()
        setupLayout()
        setupSuggestionsTable()
        loadInitialFile()
        applyLiquidGlass()
        setupKeyboardAvoidance()
        installSecretGestures()
        installMountRequestPoller()
        installFinetuneRequestPoller()

        // React to live changes from the Settings tab — font size,
        // theme, word-wrap. The notification fires synchronously after
        // each setter, so a slider drag updates the editor in real time.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSettingsDidChange),
            name: Settings.didChange, object: nil)

        // After `pdflatex foo.tex` produces a PDF, surface it in the
        // editor's output preview panel so the user can see the result
        // without opening Files or switching context. Signal comes
        // from Python shell → LaTeXEngine.
        LaTeXEngine.shared.onPreviewRequest = { [weak self] pdfPath in
            DispatchQueue.main.async { self?.showImageOutput(path: pdfPath) }
        }

        // The file browser tells us when the user deletes a file or
        // folder. If the deleted URL matches our currently-open file
        // we drop all in-memory state for it — otherwise the next
        // auto-save would write the editor buffer back to disk and
        // resurrect the file the user just deleted, making the trash
        // button look broken.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFileDidDelete(_:)),
            name: .fileDidDelete,
            object: nil)

        // SceneDelegate hands us files from "Open With…" / Share Sheet /
        // drag-drop. Observer here loads the most recent imported file
        // into the editor — same path as tapping it in the file browser.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenExternalFile(_:)),
            name: .openExternalFile,
            object: nil)

        // WKWebView's WebContent process can be terminated by iOS
        // (most commonly when the app is backgrounded for a while
        // and the user comes back). Without recovery, the preview
        // pane / sheet show a blank page and the user sees the
        // chart "reset". PywebviewBridge posts this notification on
        // ``webViewWebContentProcessDidTerminate``; we respond by
        // re-issuing ``showImageOutput(path: currentOutputPath)``
        // so the chart re-renders from disk.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePreviewWebContentDied(_:)),
            name: .previewWebContentDied,
            object: nil)

        // AI CLI asked us to open a file — happens when the user
        // runs `ai` with no file loaded and the Python side creates
        // a scratch file for the session. Route through loadFile()
        // so Monaco + currentFileURL + publishCurrentEditorFile all
        // fire consistently.
        LaTeXEngine.shared.onOpenInEditorRequest = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadFile(url: URL(fileURLWithPath: path))
            }
        }

        // AI-authored edits: when the `ai` CLI applies an edit to the
        // currently-open file, we refresh Monaco's in-memory buffer so
        // the user sees the new content immediately. Without this, the
        // editor keeps showing the pre-edit content and the next
        // debounced auto-save overwrites the AI's change from disk.
        LaTeXEngine.shared.onEditorApplyRequest = { [weak self] path, content in
            DispatchQueue.main.async {
                guard let self else { return }
                // Path comparison — AI's write targets an absolute path;
                // currentFileURL might be /private/var/... while AI got
                // /var/... (iOS has /var symlinked to /private/var) or
                // the paths might differ only in symlink resolution.
                // Match if ANY of: full resolved path equal, last-path-
                // component + size equal, or raw string equal. Errs on
                // the side of updating Monaco — worse to leave a stale
                // buffer (next auto-save overwrites AI's disk write)
                // than to wrongly refresh a different file.
                let openURL = self.currentFileURL
                let editURL = URL(fileURLWithPath: path)
                let openResolved = openURL?.resolvingSymlinksInPath().standardizedFileURL.path
                let editResolved = editURL.resolvingSymlinksInPath().standardizedFileURL.path
                let openName = openURL?.lastPathComponent
                let editName = editURL.lastPathComponent
                let isMatch = (openResolved == editResolved)
                    || (openURL?.path == editURL.path)
                    || (openName != nil && openName == editName
                        && openURL?.deletingLastPathComponent().path
                            == editURL.deletingLastPathComponent().path)
                if !isMatch {
                    // Different file — don't touch Monaco, but log so
                    // the user knows the editor won't reflect the edit
                    // until they open that file.
                    NSLog("[editor-apply] skipped refresh: open=%@ edit=%@",
                          openResolved ?? "(nil)", editResolved)
                    self.appendToTerminal(
                        "$ AI edited \(editName) (not currently open — open it to see)\n",
                        isError: false)
                    return
                }

                // Kill any in-flight auto-save BEFORE setCode runs.
                // Monaco's setValue fires onDidChangeModelContent, which
                // arrives as a textChanged on this side and re-schedules
                // auto-save with the new content. But a stale save
                // queued from the user's earlier keystrokes might
                // otherwise race ahead and overwrite the AI's disk
                // write with its pre-AI buffer. Cancel it explicitly,
                // then update lastSavedText so the next save (which
                // setCode is about to trigger) sees text == lastSaved
                // and no-ops.
                self.autoSaveTimer?.cancel()
                self.autoSaveTimer = nil
                self.pendingSaveText = nil
                self.lastSavedText = content

                let lang = self.currentLanguage.monacoName
                self.monacoView.setCode(content, language: lang)
                self.codeTextView.text = content        // legacy mirror
                self.appendToTerminal(
                    "$ AI applied edit to \(editName)\n",
                    isError: false)
            }
        }

        // Forward LaTeX engine progress to the terminal so the user
        // sees real progress while a compile runs (instead of staring
        // at "First run: loading latex.ltx kernel…" for 60 s). Both
        // engines share the same contract — only one is active per
        // compile based on OFFLINAI_ENGINE, but we hook both so either
        // can surface without checking the env var here.
        let onProgress: (String) -> Void = { [weak self] msg in
            DispatchQueue.main.async {
                self?.appendToTerminal("[latex] \(msg)\n", isError: false)
            }
        }
        WebLaTeXEngine.shared.onProgress = onProgress
        BusytexEngine.shared.onProgress = onProgress

        // Build the Python symbol index in the background (first-launch only)
        PythonSymbolIndex.shared.buildIfNeeded()
    }

    // MARK: - Autocomplete Suggestions

    private func setupSuggestionsTable() {
        suggestionsTable.translatesAutoresizingMaskIntoConstraints = false
        suggestionsTable.backgroundColor = UIColor(white: 0.13, alpha: 1)
        suggestionsTable.layer.borderColor = UIColor(white: 0.25, alpha: 1).cgColor
        suggestionsTable.layer.borderWidth = 0.5
        suggestionsTable.layer.cornerRadius = 6
        suggestionsTable.clipsToBounds = true
        suggestionsTable.rowHeight = 28
        suggestionsTable.separatorStyle = .none
        suggestionsTable.dataSource = self
        suggestionsTable.delegate = self
        suggestionsTable.isHidden = true
        suggestionsTable.register(UITableViewCell.self, forCellReuseIdentifier: "suggestion")
        suggestionsTable.showsVerticalScrollIndicator = false

        view.addSubview(suggestionsTable)
        NSLayoutConstraint.activate([
            suggestionsTable.widthAnchor.constraint(equalToConstant: 260),
            suggestionsTable.heightAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])
        suggestionsTable.layer.shadowColor = UIColor.black.cgColor
        suggestionsTable.layer.shadowOpacity = 0.4
        suggestionsTable.layer.shadowRadius = 8
        suggestionsTable.layer.shadowOffset = CGSize(width: 0, height: 4)
        suggestionsTable.layer.masksToBounds = false

        setupDocPreviewPanel()
        setupSignatureTooltip()
    }

    /// Side panel beside the suggestions list that shows the focused item's
    /// signature + docstring (populated by the Python daemon via resolve).
    private func setupDocPreviewPanel() {
        docPreviewPanel.translatesAutoresizingMaskIntoConstraints = false
        docPreviewPanel.backgroundColor = UIColor(white: 0.10, alpha: 1)
        docPreviewPanel.layer.borderColor = UIColor(white: 0.22, alpha: 1).cgColor
        docPreviewPanel.layer.borderWidth = 0.5
        docPreviewPanel.layer.cornerRadius = 6
        docPreviewPanel.clipsToBounds = true
        docPreviewPanel.isHidden = true
        docPreviewPanel.layer.shadowColor = UIColor.black.cgColor
        docPreviewPanel.layer.shadowOpacity = 0.4
        docPreviewPanel.layer.shadowRadius = 8
        docPreviewPanel.layer.shadowOffset = CGSize(width: 0, height: 4)
        docPreviewPanel.layer.masksToBounds = false

        docPreviewSignatureLabel.translatesAutoresizingMaskIntoConstraints = false
        docPreviewSignatureLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        docPreviewSignatureLabel.textColor = UIColor(red: 0.55, green: 0.80, blue: 0.95, alpha: 1)
        docPreviewSignatureLabel.numberOfLines = 0
        docPreviewSignatureLabel.lineBreakMode = .byWordWrapping

        docPreviewTextView.translatesAutoresizingMaskIntoConstraints = false
        docPreviewTextView.isEditable = false
        docPreviewTextView.isScrollEnabled = true
        docPreviewTextView.backgroundColor = .clear
        docPreviewTextView.textColor = UIColor(white: 0.80, alpha: 1)
        docPreviewTextView.font = .systemFont(ofSize: 11)
        docPreviewTextView.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        docPreviewPanel.addSubview(docPreviewSignatureLabel)
        docPreviewPanel.addSubview(docPreviewTextView)

        view.addSubview(docPreviewPanel)

        NSLayoutConstraint.activate([
            docPreviewPanel.widthAnchor.constraint(equalToConstant: 300),
            docPreviewPanel.heightAnchor.constraint(equalToConstant: 200),

            docPreviewSignatureLabel.topAnchor.constraint(equalTo: docPreviewPanel.topAnchor, constant: 10),
            docPreviewSignatureLabel.leadingAnchor.constraint(equalTo: docPreviewPanel.leadingAnchor, constant: 10),
            docPreviewSignatureLabel.trailingAnchor.constraint(equalTo: docPreviewPanel.trailingAnchor, constant: -10),

            docPreviewTextView.topAnchor.constraint(equalTo: docPreviewSignatureLabel.bottomAnchor, constant: 6),
            docPreviewTextView.leadingAnchor.constraint(equalTo: docPreviewPanel.leadingAnchor, constant: 10),
            docPreviewTextView.trailingAnchor.constraint(equalTo: docPreviewPanel.trailingAnchor, constant: -10),
            docPreviewTextView.bottomAnchor.constraint(equalTo: docPreviewPanel.bottomAnchor, constant: -10),
        ])
    }

    /// Floating tooltip that appears above the cursor when the user types `(`
    /// to show the function signature.
    private func setupSignatureTooltip() {
        signatureTooltip.translatesAutoresizingMaskIntoConstraints = false
        signatureTooltip.backgroundColor = UIColor(white: 0.10, alpha: 1)
        signatureTooltip.layer.borderColor = UIColor(white: 0.25, alpha: 1).cgColor
        signatureTooltip.layer.borderWidth = 0.5
        signatureTooltip.layer.cornerRadius = 6
        signatureTooltip.isHidden = true
        signatureTooltip.layer.shadowColor = UIColor.black.cgColor
        signatureTooltip.layer.shadowOpacity = 0.4
        signatureTooltip.layer.shadowRadius = 6
        signatureTooltip.layer.shadowOffset = CGSize(width: 0, height: 3)

        signatureTooltipLabel.translatesAutoresizingMaskIntoConstraints = false
        signatureTooltipLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        signatureTooltipLabel.textColor = UIColor(white: 0.90, alpha: 1)
        signatureTooltipLabel.numberOfLines = 0

        signatureTooltip.addSubview(signatureTooltipLabel)
        view.addSubview(signatureTooltip)

        NSLayoutConstraint.activate([
            signatureTooltipLabel.topAnchor.constraint(equalTo: signatureTooltip.topAnchor, constant: 8),
            signatureTooltipLabel.leadingAnchor.constraint(equalTo: signatureTooltip.leadingAnchor, constant: 10),
            signatureTooltipLabel.trailingAnchor.constraint(equalTo: signatureTooltip.trailingAnchor, constant: -10),
            signatureTooltipLabel.bottomAnchor.constraint(equalTo: signatureTooltip.bottomAnchor, constant: -8),
            signatureTooltip.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    /// Base candidates for the current language (keywords + builtins, no library symbols)
    private var baseCandidates: [String] {
        switch currentLanguage {
        case .python:
            return Array(Self.pythonKeywords) + Self.pythonBuiltins
        case .c:
            return Array(Self.cKeywords) + Self.cBuiltins
        case .cpp:
            return Array(Self.cppKeywords) + Self.cppBuiltins
        case .fortran:
            return Array(Self.fortranKeywords) + Self.fortranBuiltins
        case .swift:
            return Array(Self.swiftKeywords) + Self.swiftBuiltins
        case .latex:
            // No autocomplete dictionary for LaTeX yet — Monaco's
            // built-in tokenizer handles syntax highlighting; symbol
            // hints would need a TeX-specific dictionary which we
            // haven't curated. Empty list = fall-through to base
            // editor behavior (just typed-prefix matching).
            return []
        }
    }

    /// Update suggestions based on the current word + context (member access vs bare).
    /// Produces kind-annotated `CompletionItem`s that drive icons and colors.
    private func updateSuggestions() {
        guard let text = codeTextView.text else { hideSuggestions(); return }
        let selected = codeTextView.selectedRange
        let cursorLoc = selected.location + selected.length
        let ns = text as NSString
        guard cursorLoc <= ns.length else { hideSuggestions(); return }

        // Find the word/expression prefix to the left of the cursor (letters, digits, _, .)
        var start = cursorLoc
        let wordChars = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "_."))
        while start > 0 {
            let ch = ns.substring(with: NSRange(location: start - 1, length: 1))
            if let scalar = ch.unicodeScalars.first, wordChars.contains(scalar) {
                start -= 1
            } else {
                break
            }
        }

        let prefix = ns.substring(with: NSRange(location: start, length: cursorLoc - start))

        var items: [CompletionItem] = []
        var replaceRange: NSRange
        var matchPrefix: String

        if currentLanguage == .python, prefix.contains(".") {
            // ── Member access: "np.ar" → qualifier="np", member="ar" ──
            let components = prefix.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let qualifier = components.first ?? ""
            let member = components.count > 1 ? components.last ?? "" : ""

            guard !qualifier.isEmpty else { hideSuggestions(); return }

            let parsed = PythonImportScanner.scan(text)
            let resolvedModule = PythonSymbolIndex.shared.resolveAlias(qualifier, aliases: parsed.aliases)
            let memberPairs = PythonSymbolIndex.shared.membersWithKinds(of: qualifier, aliases: parsed.aliases)
            guard !memberPairs.isEmpty else { hideSuggestions(); return }

            items = memberPairs.map { pair in
                CompletionItem(label: pair.name, kind: pair.kind, detail: resolvedModule, module: resolvedModule)
            }

            // Replace only the part after the last dot
            let dotPos = prefix.lastIndex(of: ".")!
            let afterDotOffset = prefix.distance(from: prefix.startIndex, to: dotPos) + 1
            replaceRange = NSRange(location: start + afterDotOffset, length: cursorLoc - (start + afterDotOffset))
            matchPrefix = member
        } else {
            // ── Bare identifier — keywords + builtins + imports ──
            guard prefix.count >= 1 else { hideSuggestions(); return }

            // 1. Keywords
            for kw in baseCandidates {
                let kind = IntelliSenseEngine.classify(kw, inModule: nil)
                let detail = kind == .keyword ? "keyword" : "builtin"
                items.append(CompletionItem(label: kw, kind: kind, detail: detail))
            }

            if currentLanguage == .python {
                let parsed = PythonImportScanner.scan(text)

                // 2. Import aliases (np, plt, ...)
                for (alias, mod) in parsed.aliases {
                    items.append(CompletionItem(label: alias, kind: .module, detail: mod, module: mod))
                }
                for (alias, mod) in PythonSymbolIndex.shared.defaultAliases where parsed.aliases[alias] == nil {
                    items.append(CompletionItem(label: alias, kind: .module, detail: "→ \(mod)", module: mod))
                }
                // 3. `from X import foo` — foo usable bare
                for (sym, mod) in parsed.fromImports {
                    let k = PythonSymbolIndex.shared.kind(of: sym, in: mod)
                    items.append(CompletionItem(label: sym, kind: k, detail: mod, module: mod))
                }
                // 4. `from X import *` — all of X's members usable bare
                for mod in parsed.wildcardImports {
                    for (name, kind) in PythonSymbolIndex.shared.membersWithKinds(of: mod) {
                        items.append(CompletionItem(label: name, kind: kind, detail: mod, module: mod))
                    }
                }
                // 5. Module names (for `import X`)
                for mod in PythonSymbolIndex.shared.allModules {
                    items.append(CompletionItem(label: mod, kind: .module, detail: "module", module: mod))
                }
            }

            replaceRange = NSRange(location: start, length: cursorLoc - start)
            matchPrefix = prefix
        }

        // Filter by prefix
        let lowerPrefix = matchPrefix.lowercased()
        var seen: Set<String> = []
        let filtered = items.filter { item in
            guard item.label.lowercased().hasPrefix(lowerPrefix), item.label != matchPrefix else { return false }
            if seen.contains(item.label) { return false }
            seen.insert(item.label)
            return true
        }
        .sorted { lhs, rhs in
            // Exact-case prefix match first, then kind priority, then length
            let lhsExact = lhs.label.hasPrefix(matchPrefix)
            let rhsExact = rhs.label.hasPrefix(matchPrefix)
            if lhsExact != rhsExact { return lhsExact }
            if lhs.kind.sortPriority != rhs.kind.sortPriority {
                return lhs.kind.sortPriority < rhs.kind.sortPriority
            }
            return lhs.label.count < rhs.label.count
        }
        .prefix(15)

        if filtered.isEmpty {
            hideSuggestions()
            return
        }

        currentSuggestions = Array(filtered)
        currentMatchPrefix = matchPrefix
        suggestionTriggerRange = replaceRange
        suggestionsTable.reloadData()
        positionSuggestionsTable()
        suggestionsTable.isHidden = false
        suggestionsHidden = false
    }

    private func positionSuggestionsTable() {
        // Place the suggestion table below the current cursor position
        guard let selectedRange = codeTextView.selectedTextRange else { return }
        let caretRect = codeTextView.caretRect(for: selectedRange.end)
        let globalRect = codeTextView.convert(caretRect, to: view)

        // Adjust height based on number of suggestions
        let rows = min(currentSuggestions.count, 7)
        let tableHeight = CGFloat(rows) * 28 + 4

        // Remove old position constraints
        suggestionsTable.constraints.forEach { _ in }
        for constraint in view.constraints {
            if constraint.firstItem === suggestionsTable || constraint.secondItem === suggestionsTable {
                if constraint.firstAttribute == .top || constraint.firstAttribute == .leading || constraint.firstAttribute == .height {
                    constraint.isActive = false
                }
            }
        }

        NSLayoutConstraint.activate([
            suggestionsTable.topAnchor.constraint(equalTo: view.topAnchor, constant: globalRect.maxY + 4),
            suggestionsTable.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: globalRect.minX),
            suggestionsTable.heightAnchor.constraint(equalToConstant: tableHeight),
        ])
        view.bringSubviewToFront(suggestionsTable)
    }

    private func hideSuggestions() {
        suggestionsTable.isHidden = true
        suggestionsHidden = true
        currentSuggestions = []
        suggestionTriggerRange = nil
        hideDocPreview()
    }

    // MARK: - Signature Help (triggered by `(`)

    /// Detect when user types `(` after an identifier and show signature tooltip.
    /// Called from `shouldChangeTextIn` when `text == "("`.
    private func handleSignatureHelpTrigger() {
        guard currentLanguage == .python else { return }
        guard let text = codeTextView.text else { return }
        let selected = codeTextView.selectedRange
        let cursorLoc = selected.location
        let ns = text as NSString
        guard cursorLoc > 0, cursorLoc <= ns.length else { return }

        // Walk backward from cursor to find the identifier that was just typed before `(`
        let end = cursorLoc
        var start = cursorLoc
        let idChars = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "_."))
        while start > 0 {
            let ch = ns.substring(with: NSRange(location: start - 1, length: 1))
            if let scalar = ch.unicodeScalars.first, idChars.contains(scalar) {
                start -= 1
            } else {
                break
            }
        }
        guard start < end else { return }
        let expr = ns.substring(with: NSRange(location: start, length: end - start))
        guard !expr.isEmpty else { return }

        // Split into qualifier.name
        let components = expr.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let qualifier: String
        let name: String
        if components.count >= 2 {
            qualifier = components.dropLast().joined(separator: ".")
            name = components.last ?? ""
        } else {
            // Bare call like `print(` — qualifier is builtins
            qualifier = "builtins"
            name = expr
        }

        // Resolve qualifier via imports
        let parsed = PythonImportScanner.scan(text)
        let resolvedModule = PythonSymbolIndex.shared.resolveAlias(qualifier, aliases: parsed.aliases)

        let probe = CompletionItem(label: name, kind: .function, detail: resolvedModule, module: resolvedModule)

        // Show placeholder tooltip immediately
        positionSignatureTooltipNearCursor()
        signatureTooltipLabel.text = "\(name)(...)  loading..."
        signatureTooltip.isHidden = false
        signatureTooltipVisible = true

        IntelliSenseEngine.shared.resolve(probe) { [weak self] resolved in
            guard let self, self.signatureTooltipVisible else { return }
            let sig = resolved.signature ?? ""
            if sig.isEmpty {
                self.hideSignatureTooltip()
            } else {
                self.signatureTooltipLabel.text = "\(name)\(sig)"
            }
        }
    }

    private func positionSignatureTooltipNearCursor() {
        guard let selectedRange = codeTextView.selectedTextRange else { return }
        let caretRect = codeTextView.caretRect(for: selectedRange.end)
        let globalRect = codeTextView.convert(caretRect, to: view)

        for c in view.constraints where (c.firstItem === signatureTooltip || c.secondItem === signatureTooltip) {
            if c.firstAttribute == .top || c.firstAttribute == .leading {
                c.isActive = false
            }
        }

        NSLayoutConstraint.activate([
            signatureTooltip.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: max(8, globalRect.minX)),
            signatureTooltip.bottomAnchor.constraint(equalTo: view.topAnchor, constant: max(40, globalRect.minY - 4)),
        ])
        view.bringSubviewToFront(signatureTooltip)
    }

    private func hideSignatureTooltip() {
        signatureTooltip.isHidden = true
        signatureTooltipVisible = false
    }

    private func applySuggestion(_ item: CompletionItem) {
        guard let triggerRange = suggestionTriggerRange, let text = codeTextView.text else { return }
        let ns = text as NSString
        let newText = ns.replacingCharacters(in: triggerRange, with: item.insertText)
        codeTextView.text = newText
        let newLoc = triggerRange.location + (item.insertText as NSString).length
        codeTextView.selectedRange = NSRange(location: newLoc, length: 0)
        applySyntaxHighlighting()
        updateLineNumbers()
        hideSuggestions()
    }

    // MARK: - Liquid Glass (iOS 26+)

    private func applyLiquidGlass() {
        // Use subtle dark blur instead of UIGlassEffect (which goes light on dark backgrounds)
        // This gives a high-tech frosted dark glass look that works with our dark theme

        // Toolbar: dark ultra-thin material
        let toolbarBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        toolbarBlur.translatesAutoresizingMaskIntoConstraints = false
        toolbar.insertSubview(toolbarBlur, at: 0)
        NSLayoutConstraint.activate([
            toolbarBlur.topAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbarBlur.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarBlur.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            toolbarBlur.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
        ])
        toolbar.backgroundColor = UIColor(white: 0.08, alpha: 0.6)

        // Terminal title bar: subtle dark material
        let termBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        termBlur.translatesAutoresizingMaskIntoConstraints = false
        terminalTitleBar.insertSubview(termBlur, at: 0)
        NSLayoutConstraint.activate([
            termBlur.topAnchor.constraint(equalTo: terminalTitleBar.topAnchor),
            termBlur.leadingAnchor.constraint(equalTo: terminalTitleBar.leadingAnchor),
            termBlur.trailingAnchor.constraint(equalTo: terminalTitleBar.trailingAnchor),
            termBlur.bottomAnchor.constraint(equalTo: terminalTitleBar.bottomAnchor),
        ])
        terminalTitleBar.backgroundColor = UIColor(white: 0.06, alpha: 0.5)
    }

    /// True when running in a horizontally-compact size class — iPhone
    /// in any orientation, narrow Slide Over on iPad. Used to drop
    /// button labels (icon-only secondary buttons) so the toolbar
    /// fits without overflowing.
    private var isCompactWidth: Bool {
        traitCollection.horizontalSizeClass == .compact
            || UIDevice.current.userInterfaceIdiom == .phone
    }

    // MARK: - Setup Toolbar

    private func setupToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = EditorTheme.background.withAlphaComponent(0.95)

        // Language control is hidden — auto-detected from file extension
        languageControl.selectedSegmentIndex = 0
        languageControl.isHidden = true

        // Run button — emerald GRADIENT capsule per the Claude Design
        // source (styles/editor.css → .ed-btn.run). Specifics ported
        // 1:1 from the design CSS so the on-device look matches the
        // mockup the user reviewed:
        //   background  linear-gradient(180deg, #3ee0a8 0%, #22c08a 100%)
        //   color       #052016 (dark forest green, NOT white)
        //   shadow      0 0 0 1px rgba(52,211,153,0.18) (outline)
        //              + 0 6px 16px -4px rgba(52,211,153,0.35) (drop)
        //              + 0 1px 0 rgba(255,255,255,0.35) inset (highlight)
        var runConfig = UIButton.Configuration.plain()
        runConfig.image = UIImage(systemName: "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        var runTitleAttr = AttributeContainer()
        runTitleAttr.font = UIFont.systemFont(ofSize: 13, weight: .semibold).rounded
        runConfig.attributedTitle = AttributedString("Run", attributes: runTitleAttr)
        runConfig.imagePadding = 6
        runConfig.baseForegroundColor = UIColor(red: 0x05/255.0, green: 0x20/255.0, blue: 0x16/255.0, alpha: 1.0)
        runConfig.cornerStyle = .capsule
        runConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 14)
        runConfig.background.backgroundColor = .clear
        runButton.configuration = runConfig
        runButton.addTarget(self, action: #selector(runTapped), for: .touchUpInside)
        runButton.translatesAutoresizingMaskIntoConstraints = false
        runButton.isPointerInteractionEnabled = true
        // Apply the emerald gradient + triple shadow via layer hooks.
        // CAGradientLayer is added in viewDidLayoutSubviews so we have
        // a sized frame; do an initial pass here with a zero frame so
        // the layer exists for hit-testing.
        applyRunButtonStyle()

        // Secondary toolbar buttons share a consistent style:
        //   • Tinted (subtle filled background) instead of plain
        //   • Rounded font matching Run
        //   • Same vertical inset → same height as Run
        // Plus pointer interaction for trackpad users.
        func styleSecondary(_ button: UIButton, title: String?, icon: String, color: UIColor) {
            // Ghost-style: no background, just icon + label in a
            // muted-but-readable tint. The Claude Design merge demoted
            // these so Run pops as the only filled-capsule on the
            // toolbar; previously every button competed for attention.
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: icon,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            if let t = title {
                var attr = AttributeContainer()
                attr.font = UIFont.systemFont(ofSize: 12, weight: .medium).rounded
                cfg.attributedTitle = AttributedString(t, attributes: attr)
                cfg.imagePadding = 5
            }
            // Demote saturation — the call-site colour is the *role*,
            // not the on-screen tint. 78% opacity reads "muted ghost"
            // rather than "tinted call-to-action".
            cfg.baseForegroundColor = color.withAlphaComponent(0.78)
            cfg.cornerStyle = .capsule
            cfg.contentInsets = NSDirectionalEdgeInsets(
                top: 6,
                leading: title == nil ? 8 : 10,
                bottom: 6,
                trailing: title == nil ? 8 : 10)
            button.configuration = cfg
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isPointerInteractionEnabled = true
        }

        // Drop labels on compact width — iPhone toolbar would otherwise
        // overflow with five labeled buttons. Icons stay; the SF Symbol
        // is enough to read what each button does.
        let compact = isCompactWidth
        // Files-panel toggle — collapses/expands the embedded file
        // browser on the left of the editor. Uses `sidebar.left`
        // (iOS 14+) for both states; the only state difference is
        // the foreground colour — bright accent when panel is open,
        // muted grey when collapsed. (`sidebar.left.fill` was added
        // in iOS 18 and returns nil on the iOS 17 deployment target,
        // which is why the button rendered as an empty black box
        // before this fix.)
        //
        // Pinned with required compression resistance + minimum width
        // so the toolbar never squeezes this button to invisibility
        // when the editor pane narrows (AI chat opens, iPhone portrait,
        // rotation).
        styleSecondary(filesToggleButton,
                       title: nil,
                       icon: "sidebar.left",
                       color: EditorTheme.accent)
        filesToggleButton.addTarget(self, action: #selector(toggleEditorFilesPanel),
                                    for: .touchUpInside)
        filesToggleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        filesToggleButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        filesToggleButton.setContentHuggingPriority(.required, for: .horizontal)
        styleSecondary(openFileButton, title: compact ? nil : "Open", icon: "folder.badge.plus",
                       color: EditorTheme.accent)
        openFileButton.addTarget(self, action: #selector(openFileTapped), for: .touchUpInside)

        styleSecondary(clearButton, title: nil, icon: "trash",
                       color: UIColor(white: 0.6, alpha: 1.0))
        clearButton.addTarget(self, action: #selector(clearTerminal), for: .touchUpInside)

        // Templates button removed from toolbar (templates accessible via file explorer)

        // AI Assist button is configured in setupEditor() — nothing to do here.
        // The button lives in the editor header bar (violet-indigo pill).

        styleSecondary(latexTestButton, title: compact ? nil : "LaTeX", icon: "function",
                       color: .systemPink)
        latexTestButton.addTarget(self, action: #selector(showLaTeXPreview), for: .touchUpInside)

        // Renamed from a bare gear icon to "Manim" so its purpose
        // (manim quality / fps controls only) is clear at a glance —
        // the gear icon alone was misread as global-app settings.
        // On compact width we drop the label too; the gear is recognized.
        styleSecondary(settingsButton, title: compact ? nil : "Manim", icon: "gearshape.fill",
                       color: .systemPurple)
        settingsButton.addTarget(self, action: #selector(toggleSettingsPanel), for: .touchUpInside)

        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Docs button removed — Docs available via top-level Docs tab
        // AI Assist button moved to editor header (see setupEditor)

        // Auto-preload toggle — small icon in the top-right toolbar.
        // Shows whether the most-recently-used GGUF will be loaded
        // automatically on the next launch. Tap to toggle.
        let preloadButton = UIButton(type: .system)
        preloadButton.translatesAutoresizingMaskIntoConstraints = false
        preloadButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        preloadButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        preloadButton.addTarget(self, action: #selector(togglePreload(_:)),
                                for: .touchUpInside)
        preloadButton.tag = 9001          // for togglePreload to find it
        refreshPreloadButton(preloadButton)
        self.preloadToggleButton = preloadButton

        // Toolbar groups: [Run] · [file actions: Open · Clear] · spacer ·
        // [right-side utilities: Preload · LaTeX · Manim] · [status tail:
        // Ln Col · UTF-8 · ● Ready]. The Claude Design pass folded the
        // legacy 22pt status strip into the toolbar tail so the editor
        // body gets that vertical space back. Hairline dividers
        // separate logical groups (Mail.app / Maps.app idiom).
        // iPhone toolbar: drop the status tail (Ln · Col · UTF-8 · Ready)
        // since the toolbar physically can't fit the secondaries +
        // status info on a 390pt phone screen. Cursor info still
        // updates the underlying labels — they just aren't mounted in
        // the toolbar. On iPad we keep the full status tail.
        // RAM sparkline — pinned in the toolbar between the spacer
        // and the preload button so it sits in the right-hand status
        // group. 140×26 matches the same widget on the home screen.
        editorMemoryGraph.translatesAutoresizingMaskIntoConstraints = false
        editorMemoryGraph.widthAnchor.constraint(equalToConstant: 140).isActive = true
        editorMemoryGraph.heightAnchor.constraint(equalToConstant: 26).isActive = true

        // Toolbar contents differ for iPhone (compact) vs iPad
        // (regular). On iPhone the previous layout overflowed:
        // Run + 3 file buttons + RAM graph (140 pt) + preload + LaTeX
        // test + settings + 3 dividers + ~5 status labels can't fit
        // in ~390 pt of width. The Run button visibly clipped into
        // the PYTHON file-tab badge underneath. Compact branch now
        // drops the secondary widgets — RAM graph (visible on System
        // tab anyway), LaTeX test (niche), status tail labels —
        // and keeps the action buttons that matter for editing.
        var toolbarItems: [UIView] = [
            runButton,
            toolbarDivider(),
            filesToggleButton, openFileButton, clearButton,
            spacer,
        ]
        if compact {
            // iPhone: keep only the essentials on the right —
            // preload (model warm-up) + settings. RAM gauge and
            // LaTeX test are easily reachable via System / Math
            // dashboards; not worth blocking the editor for.
            toolbarItems.append(preloadButton)
            toolbarItems.append(settingsButton)
        } else {
            // iPad: full status row.
            toolbarItems.append(editorMemoryGraph)
            toolbarItems.append(toolbarDivider())
            toolbarItems.append(preloadButton)
            toolbarItems.append(toolbarDivider())
            toolbarItems.append(latexTestButton)
            toolbarItems.append(settingsButton)
            toolbarItems.append(toolbarDivider())
            toolbarItems.append(statusCursorLabel)
            toolbarItems.append(statusEncodingLabel)
            toolbarItems.append(statusStateDot)
            toolbarItems.append(statusStateLabel)
        }
        let toolbarStack = UIStackView(arrangedSubviews: toolbarItems)
        toolbarStack.axis = .horizontal
        toolbarStack.spacing = 10
        toolbarStack.alignment = .center
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        // The status-tail labels should never grow / shrink against
        // their content; keep them hugging tightly so the secondary
        // buttons hug too and the spacer claims the slack.
        statusCursorLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusEncodingLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusStateLabel.setContentHuggingPriority(.required, for: .horizontal)

        toolbar.addSubview(toolbarStack)
        NSLayoutConstraint.activate([
            toolbarStack.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 6),
            toolbarStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            toolbarStack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            toolbarStack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -6)
        ])
    }

    /// One-time configuration of the status-tail labels (cursor /
    /// encoding / state dot + label) that the Claude Design merge
    /// moved from the bottom status bar into the toolbar's right side.
    /// The labels are property-level UIViews so other code paths that
    /// poke their `.text` (loadFile, monacoView.onCursorChanged,
    /// updateEditorStatusState…) keep working without changes.
    private func configureToolbarStatusTail() {
        let monoFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)

        statusStateDot.backgroundColor = TerminalStatus.ready.color
        statusStateDot.layer.cornerRadius = 3
        statusStateDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusStateDot.widthAnchor.constraint(equalToConstant: 6),
            statusStateDot.heightAnchor.constraint(equalToConstant: 6),
        ])

        statusStateLabel.font = monoFont
        statusStateLabel.textColor = UIColor(white: 0.65, alpha: 1)
        statusStateLabel.text = "Ready"
        statusStateLabel.translatesAutoresizingMaskIntoConstraints = false

        statusCursorLabel.font = monoFont
        statusCursorLabel.textColor = UIColor(white: 0.55, alpha: 1)
        statusCursorLabel.text = "Ln 1, Col 1"
        statusCursorLabel.translatesAutoresizingMaskIntoConstraints = false

        statusEncodingLabel.font = monoFont
        statusEncodingLabel.textColor = UIColor(white: 0.45, alpha: 1)
        statusEncodingLabel.text = "UTF-8"
        statusEncodingLabel.translatesAutoresizingMaskIntoConstraints = false

        // The legacy status-bar property + buildEditorStatusBar() are
        // still referenced from setupEditor-adjacent code paths (e.g.
        // updateEditorStatusBar) — they continue to work because they
        // only mutate .text on the same labels that now live in the
        // toolbar. statusFileLabel and statusLanguageLabel stay
        // unmounted (the editor header pill covers their info).
    }

    /// 0.5pt × 18pt vertical hairline separating toolbar groups.
    /// Mirrors `separatorView()` in the status bar but tuned for the
    /// toolbar's larger button height. UIStackView treats it like any
    /// other arranged subview — no extra constraints needed.
    private func toolbarDivider() -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor(white: 0.28, alpha: 1)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    // MARK: - Setup Editor

    private func setupEditor() {
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.backgroundColor = EditorTheme.background
        editorContainer.layer.cornerRadius = 0
        editorContainer.clipsToBounds = true

        // ── Editor header: VS Code-style tab bar ──
        //
        // Layout, left → right:
        //   [active tab pill]            [language pill]   [AI toggle (hidden)]
        //
        // The active tab pill is a single-file tab today (no multi-file
        // tabbing yet — the file browser handles file switching). The
        // pill itself carries an SF Symbol icon (per-language), the
        // filename, a modified-state dot, and a top accent bar so it
        // reads as the active tab. A bottom hairline separates the
        // header bar from Monaco below.
        editorHeaderBar.translatesAutoresizingMaskIntoConstraints = false
        editorHeaderBar.backgroundColor = EditorTheme.gutterBg
        let headerBorder = UIView()
        headerBorder.translatesAutoresizingMaskIntoConstraints = false
        headerBorder.backgroundColor = EditorTheme.borderSub
        editorHeaderBar.addSubview(headerBorder)

        // File tab pill: SF Symbol icon + filename + modified dot.
        let fileTabPill = UIView()
        fileTabPill.translatesAutoresizingMaskIntoConstraints = false
        // Design CSS .ed-tab specifies bg #1a1a24 (slightly lighter than
        // the pane bg), border --border-soft (rgba 255,255,255,0.06),
        // radius 8. The top accent sits 1pt ABOVE the pill so clipping
        // is intentionally off; the rounded corners still apply because
        // we use a layer cornerRadius.
        fileTabPill.backgroundColor = UIColor(red: 0x1a/255.0, green: 0x1a/255.0, blue: 0x24/255.0, alpha: 1.0)
        fileTabPill.layer.cornerRadius = 8
        fileTabPill.layer.cornerCurve = .continuous
        fileTabPill.layer.borderColor = UIColor.white.withAlphaComponent(0.06).cgColor
        fileTabPill.layer.borderWidth = 1
        fileTabPill.clipsToBounds = false

        // Top accent bar — 1.5pt strip pinned to the pill's top edge.
        tabTopAccent.translatesAutoresizingMaskIntoConstraints = false
        tabTopAccent.backgroundColor = EditorTheme.accentViolet
        fileTabPill.addSubview(tabTopAccent)

        fileIconView.translatesAutoresizingMaskIntoConstraints = false
        fileIconView.contentMode = .scaleAspectFit
        fileIconView.tintColor = EditorTheme.accentViolet
        fileIconView.image = UIImage(
            systemName: "chevron.left.forward.slash.chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))

        editorFileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        editorFileNameLabel.text = "main.py"
        editorFileNameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        editorFileNameLabel.textColor = EditorTheme.foreground
        editorFileNameLabel.lineBreakMode = .byTruncatingMiddle
        editorFileNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Modified-state dot — hidden when the buffer matches disk.
        modifiedDot.translatesAutoresizingMaskIntoConstraints = false
        modifiedDot.backgroundColor = EditorTheme.string  // amber — same as Xcode
        modifiedDot.layer.cornerRadius = 3
        modifiedDot.isHidden = true

        fileTabPill.addSubview(fileIconView)
        fileTabPill.addSubview(editorFileNameLabel)
        fileTabPill.addSubview(modifiedDot)

        // Right-side language pill — capsule showing current language.
        langPill.translatesAutoresizingMaskIntoConstraints = false
        langPill.text = "  Python  "
        langPill.font = .systemFont(ofSize: 10, weight: .semibold)
        langPill.textColor = EditorTheme.accent
        langPill.textAlignment = .center
        langPill.backgroundColor = EditorTheme.accent.withAlphaComponent(0.12)
        langPill.layer.cornerRadius = 5
        langPill.layer.cornerCurve = .continuous
        langPill.layer.borderColor = EditorTheme.accent.withAlphaComponent(0.30).cgColor
        langPill.layer.borderWidth = 0.5
        langPill.clipsToBounds = true

        // AI Assist toggle — HIDDEN. The inline chat panel is deprecated
        // in favour of the `ai` shell command which offers a much richer
        // CLI experience (slash commands, permission modes, multi-file
        // edits, usage stats). The button is still instantiated and
        // wired up so the rest of the view hierarchy doesn't need
        // conditional guards, but it's taken out of the header bar
        // and never shown. Re-enable by setting aiToggleButton.isHidden
        // = false and re-adding it as a subview if you want the panel
        // back.
        aiToggleButton.translatesAutoresizingMaskIntoConstraints = false
        aiToggleButton.layer.cornerRadius = 6
        aiToggleButton.layer.cornerCurve = .continuous
        aiToggleButton.layer.borderWidth = 1
        aiToggleButton.addTarget(self, action: #selector(toggleAIChat), for: .touchUpInside)
        // Button stays in the view hierarchy (so the trailing /
        // centerY / height constraints below still resolve — removing
        // it from the header hits "no common ancestor" at activate
        // time), but isHidden + alpha 0 keep it invisible and
        // non-interactive. Re-enable the AI-chat entry point by
        // flipping isHidden = false + alpha = 1.
        aiToggleButton.isHidden = true
        aiToggleButton.alpha = 0
        aiToggleButton.isUserInteractionEnabled = false
        applyAIToggleStyle()

        // Right-side header content — breadcrumb + AI Assist chip.
        // Defers to lineBreakMode .byTruncatingHead so a deep path
        // (`.../workspaces/some-long-name/sub/sub/file.py`) elides
        // from the left, keeping the file's parent dir visible.
        breadcrumbLabel.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        breadcrumbLabel.textColor = UIColor(white: 0.42, alpha: 1)
        breadcrumbLabel.lineBreakMode = .byTruncatingHead
        breadcrumbLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        aiAssistChip.translatesAutoresizingMaskIntoConstraints = false
        var aiCfg = UIButton.Configuration.plain()
        aiCfg.image = UIImage(systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        var aiAttr = AttributeContainer()
        aiAttr.font = UIFont.systemFont(ofSize: 10, weight: .semibold).rounded
        aiCfg.attributedTitle = AttributedString("AI Assist", attributes: aiAttr)
        aiCfg.imagePadding = 4
        aiCfg.baseForegroundColor = EditorTheme.accentViolet
        aiCfg.cornerStyle = .capsule
        aiCfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 10)
        aiCfg.background.backgroundColor = EditorTheme.accentViolet.withAlphaComponent(0.12)
        aiCfg.background.strokeColor = EditorTheme.accentViolet.withAlphaComponent(0.30)
        aiCfg.background.strokeWidth = 0.5
        aiAssistChip.configuration = aiCfg
        aiAssistChip.isPointerInteractionEnabled = true
        aiAssistChip.addTarget(self, action: #selector(toggleAIChat), for: .touchUpInside)

        editorHeaderBar.addSubview(fileTabPill)
        editorHeaderBar.addSubview(langPill)
        editorHeaderBar.addSubview(breadcrumbLabel)
        editorHeaderBar.addSubview(aiAssistChip)
        editorHeaderBar.addSubview(aiToggleButton)

        // Monaco editor
        monacoView.translatesAutoresizingMaskIntoConstraints = false
        monacoView.onTextChanged = { [weak self] text in
            // Mirror to legacy property for any old reader
            self?.codeTextView.text = text
            // Persist edits back to disk — without this the user's
            // edits live only in Monaco's WebView buffer and vanish
            // on app relaunch ("I edit a.tex and re-open it, it's 0B").
            self?.scheduleAutoSave(text: text)
            // Toggle the modified-state dot in the tab header.
            self?.updateModifiedDot(currentText: text)
        }
        // Live cursor position → status bar
        monacoView.onCursorChanged = { [weak self] line, col in
            self?.statusCursorLabel.text = "Ln \(line), Col \(col)"
        }

        editorContainer.addSubview(editorHeaderBar)
        editorContainer.addSubview(monacoView)
        // The legacy 22pt status strip below Monaco is gone — its state
        // dot, cursor pos, and encoding labels now live in the toolbar
        // tail (see configureToolbarStatusTail) so the editor pane
        // gains 22pt of code height back. The status-bar property and
        // its update-poking call sites are kept so unrelated code still
        // compiles; the labels are just no longer mounted.
        configureToolbarStatusTail()

        NSLayoutConstraint.activate([
            editorHeaderBar.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            editorHeaderBar.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            editorHeaderBar.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            editorHeaderBar.heightAnchor.constraint(equalToConstant: 36),

            headerBorder.bottomAnchor.constraint(equalTo: editorHeaderBar.bottomAnchor),
            headerBorder.leadingAnchor.constraint(equalTo: editorHeaderBar.leadingAnchor),
            headerBorder.trailingAnchor.constraint(equalTo: editorHeaderBar.trailingAnchor),
            headerBorder.heightAnchor.constraint(equalToConstant: 0.5),

            fileTabPill.leadingAnchor.constraint(equalTo: editorHeaderBar.leadingAnchor, constant: 10),
            fileTabPill.centerYAnchor.constraint(equalTo: editorHeaderBar.centerYAnchor),
            fileTabPill.heightAnchor.constraint(equalToConstant: 26),
            fileTabPill.trailingAnchor.constraint(lessThanOrEqualTo: langPill.leadingAnchor, constant: -8),

            // Top accent bar — INSET 8pt from each side and sitting
            // 1pt above the pill's top edge (per design CSS:
            // `.ed-tab::before { left:8px; right:8px; top:-1px }`).
            // Height 1.5pt, glow added in applyLanguageTabStyle.
            tabTopAccent.topAnchor.constraint(equalTo: fileTabPill.topAnchor, constant: -1),
            tabTopAccent.leadingAnchor.constraint(equalTo: fileTabPill.leadingAnchor, constant: 8),
            tabTopAccent.trailingAnchor.constraint(equalTo: fileTabPill.trailingAnchor, constant: -8),
            tabTopAccent.heightAnchor.constraint(equalToConstant: 1.5),

            fileIconView.leadingAnchor.constraint(equalTo: fileTabPill.leadingAnchor, constant: 9),
            fileIconView.centerYAnchor.constraint(equalTo: fileTabPill.centerYAnchor),
            fileIconView.widthAnchor.constraint(equalToConstant: 14),
            fileIconView.heightAnchor.constraint(equalToConstant: 14),

            editorFileNameLabel.leadingAnchor.constraint(equalTo: fileIconView.trailingAnchor, constant: 7),
            editorFileNameLabel.centerYAnchor.constraint(equalTo: fileTabPill.centerYAnchor),

            modifiedDot.leadingAnchor.constraint(equalTo: editorFileNameLabel.trailingAnchor, constant: 6),
            modifiedDot.trailingAnchor.constraint(equalTo: fileTabPill.trailingAnchor, constant: -9),
            modifiedDot.centerYAnchor.constraint(equalTo: fileTabPill.centerYAnchor),
            modifiedDot.widthAnchor.constraint(equalToConstant: 6),
            modifiedDot.heightAnchor.constraint(equalToConstant: 6),

            // Language pill — sits immediately to the right of the file
            // tab pill (Xcode-style). The right side of the header is
            // now occupied by the breadcrumb + AI Assist chip per the
            // Claude Design merge, so the header is balanced.
            langPill.leadingAnchor.constraint(equalTo: fileTabPill.trailingAnchor, constant: 8),
            langPill.centerYAnchor.constraint(equalTo: editorHeaderBar.centerYAnchor),
            langPill.heightAnchor.constraint(equalToConstant: 18),
            langPill.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),

            // AI Assist chip — trailing edge, violet capsule.
            aiAssistChip.trailingAnchor.constraint(equalTo: editorHeaderBar.trailingAnchor, constant: -12),
            aiAssistChip.centerYAnchor.constraint(equalTo: editorHeaderBar.centerYAnchor),
            aiAssistChip.heightAnchor.constraint(equalToConstant: 22),

            // Breadcrumb — sits between langPill and the AI Assist chip.
            breadcrumbLabel.leadingAnchor.constraint(greaterThanOrEqualTo: langPill.trailingAnchor, constant: 12),
            breadcrumbLabel.trailingAnchor.constraint(equalTo: aiAssistChip.leadingAnchor, constant: -10),
            breadcrumbLabel.centerYAnchor.constraint(equalTo: editorHeaderBar.centerYAnchor),

            aiToggleButton.trailingAnchor.constraint(equalTo: editorHeaderBar.trailingAnchor, constant: -10),
            aiToggleButton.centerYAnchor.constraint(equalTo: editorHeaderBar.centerYAnchor),
            aiToggleButton.heightAnchor.constraint(equalToConstant: 26),
            // Hidden AI toggle — zero-width so it doesn't claim layout
            // space. Kept in the hierarchy because removeFromSuperview
            // would break the trailing/centerY/height constraints above
            // ("no common ancestor"), and other code still pokes its
            // isHidden / tappable state.
            aiToggleButton.widthAnchor.constraint(equalToConstant: 0),

            monacoView.topAnchor.constraint(equalTo: editorHeaderBar.bottomAnchor),
            monacoView.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            monacoView.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            monacoView.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
        ])

        // Initial tab styling — currentLanguage defaults to .python in
        // the property declaration, so this paints the Python icon and
        // pill colour on first show. Subsequent calls (loadFile,
        // insertCode, languageChanged) re-paint when the language flips.
        applyLanguageTabStyle()
        updateBreadcrumb()
    }

    // MARK: - Editor Status Bar

    private func buildEditorStatusBar() {
        editorStatusBar.translatesAutoresizingMaskIntoConstraints = false
        editorStatusBar.backgroundColor = EditorTheme.gutterBg
        // Subtle top border so it visually separates from monaco
        let topBorder = UIView()
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        topBorder.backgroundColor = EditorTheme.borderSub
        editorStatusBar.addSubview(topBorder)
        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: editorStatusBar.topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: editorStatusBar.leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: editorStatusBar.trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 0.5),
        ])

        // Status bar is intentionally minimal — the editor header
        // already shows filename + language + modified state, so the
        // bottom strip focuses on transient session info: run state
        // (left), cursor position + encoding (right). Removing the
        // duplicates cuts the visual noise the user flagged as messy.
        let monoFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)

        // ── State dot — colored circle reflecting "ready" / "running"
        // / "error" so the user can tell at a glance whether the
        // last run succeeded.
        statusStateDot.translatesAutoresizingMaskIntoConstraints = false
        statusStateDot.backgroundColor = UIColor(red: 0.36, green: 0.85, blue: 0.55, alpha: 1.0)
        statusStateDot.layer.cornerRadius = 3
        NSLayoutConstraint.activate([
            statusStateDot.widthAnchor.constraint(equalToConstant: 6),
            statusStateDot.heightAnchor.constraint(equalToConstant: 6),
        ])

        statusStateLabel.font = monoFont
        statusStateLabel.textColor = UIColor(white: 0.65, alpha: 1)
        statusStateLabel.text = "Ready"
        statusStateLabel.translatesAutoresizingMaskIntoConstraints = false

        let stateGroup = UIStackView(arrangedSubviews: [statusStateDot, statusStateLabel])
        stateGroup.axis = .horizontal; stateGroup.spacing = 6; stateGroup.alignment = .center
        stateGroup.translatesAutoresizingMaskIntoConstraints = false

        // ── Cursor position
        statusCursorLabel.font = monoFont
        statusCursorLabel.textColor = UIColor(white: 0.55, alpha: 1)
        statusCursorLabel.text = "Ln 1, Col 1"

        // ── Encoding (always UTF-8 for everything we open)
        statusEncodingLabel.font = monoFont
        statusEncodingLabel.textColor = UIColor(white: 0.45, alpha: 1)
        statusEncodingLabel.text = "UTF-8"

        // statusFileLabel and statusLanguageLabel are still allocated
        // (the rest of the codebase pokes their .text in
        // updateEditorStatusBar / load paths) but they're no longer
        // mounted in the status bar — the header is the source of truth.

        let rightStack = UIStackView(arrangedSubviews: [
            statusCursorLabel, separatorView(),
            statusEncodingLabel
        ])
        rightStack.axis = .horizontal; rightStack.spacing = 12; rightStack.alignment = .center
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        editorStatusBar.addSubview(stateGroup)
        editorStatusBar.addSubview(rightStack)
        NSLayoutConstraint.activate([
            stateGroup.leadingAnchor.constraint(equalTo: editorStatusBar.leadingAnchor, constant: 12),
            stateGroup.centerYAnchor.constraint(equalTo: editorStatusBar.centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: editorStatusBar.trailingAnchor, constant: -12),
            rightStack.centerYAnchor.constraint(equalTo: editorStatusBar.centerYAnchor),
        ])
    }

    /// Tiny vertical hairline used as separator between status-bar
    /// segments. Same idiom as Xcode's status bar.
    private func separatorView() -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor(white: 0.30, alpha: 1)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        v.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return v
    }

    /// Update the status bar to reflect the currently-loaded file.
    /// Called from loadFile / language switches / cursor movements.
    private func updateEditorStatusBar() {
        statusFileLabel.text = currentFileURL?.lastPathComponent ?? "(no file)"
        statusLanguageLabel.text = currentLanguage.title
    }

    private func updateEditorStatusState(_ state: TerminalStatus) {
        statusStateDot.backgroundColor = state.color
        statusStateLabel.text = state.title
    }

    // MARK: - Tab Styling

    /// Re-apply the language-themed icon, accent colour, and right-side
    /// pill to the editor's single tab. Called whenever currentLanguage
    /// changes (loadFile, insertCode, the hidden segmented control, the
    /// clear-after-delete path).
    private func applyLanguageTabStyle() {
        let (symbol, tint) = iconSymbolAndTint(for: currentLanguage)
        let cfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        fileIconView.image = UIImage(systemName: symbol, withConfiguration: cfg)
        fileIconView.tintColor = tint
        // Top accent — language colour + 8pt glow shadow per design CSS
        // (`box-shadow: 0 0 8px rgba(247,103,55,0.55)` for Swift).
        tabTopAccent.backgroundColor = tint
        tabTopAccent.layer.cornerRadius = 0.75
        tabTopAccent.layer.shadowColor = tint.cgColor
        tabTopAccent.layer.shadowOpacity = 0.55
        tabTopAccent.layer.shadowOffset = .zero
        tabTopAccent.layer.shadowRadius = 4
        tabTopAccent.layer.masksToBounds = false
        // Language pill on the right of the header — design CSS:
        //   color    --swift   bg rgba(247,103,55,0.10)  border 0.28  font 10.5 mono 0.12em letter-spacing
        // We use the variable-tint version per current language.
        langPill.text = currentLanguage.title.uppercased()
        langPill.font = .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        langPill.textColor = tint
        langPill.backgroundColor = tint.withAlphaComponent(0.10)
        langPill.layer.cornerRadius = 5
        langPill.layer.borderColor = tint.withAlphaComponent(0.28).cgColor
        langPill.layer.borderWidth = 1
    }

    /// Per-language SF Symbol + colour. Falls back to a generic
    /// code-bracket symbol for anything we haven't given an explicit
    /// glyph yet (Monaco still highlights the buffer correctly — this
    /// only changes the tab decoration).
    private func iconSymbolAndTint(for lang: Language) -> (String, UIColor) {
        switch lang {
        case .python:
            return ("chevron.left.forward.slash.chevron.right",
                    UIColor(red: 0.20, green: 0.60, blue: 0.86, alpha: 1.0))   // py blue
        case .c:
            return ("c.square",
                    UIColor(red: 0.34, green: 0.51, blue: 0.74, alpha: 1.0))   // C blue
        case .cpp:
            return ("c.circle",
                    UIColor(red: 0.39, green: 0.36, blue: 0.79, alpha: 1.0))   // C++ violet
        case .fortran:
            return ("f.square",
                    UIColor(red: 0.40, green: 0.66, blue: 0.34, alpha: 1.0))   // Fortran green
        case .swift:
            return ("swift",
                    UIColor(red: 1.0,  green: 0.404, blue: 0.227, alpha: 1.0)) // #f76737
        case .latex:
            return ("function",
                    UIColor(red: 0.00, green: 0.55, blue: 0.55, alpha: 1.0))   // TeX teal
        }
    }

    /// Reveal / hide the modified-state dot in the tab header. Called
    /// from Monaco's onTextChanged debounce. We compare against
    /// lastSavedText because that's the authoritative "what's on disk"
    /// reference — pendingSaveText is only valid mid-debounce.
    private func updateModifiedDot(currentText: String) {
        let dirty = currentText != lastSavedText
        if modifiedDot.isHidden == dirty {
            modifiedDot.isHidden = !dirty
        }
    }

    /// Rebuild the path breadcrumb that sits on the editor header's
    /// right side ("Workspace / interpreter-lab / src"). Shows up to
    /// the last 3 path components of the file's parent directory; the
    /// label's `.byTruncatingHead` mode elides the start if the path
    /// is too long for the available space. Hidden when no file is
    /// loaded so the empty-state header doesn't have a stray "/".
    private func updateBreadcrumb() {
        guard let url = currentFileURL else {
            breadcrumbLabel.text = ""
            breadcrumbLabel.isHidden = true
            return
        }
        // iPhone: the editor header is already cramped with the file
        // tab pill + language pill + AI Assist chip — the breadcrumb
        // squeezes between langPill and aiAssistChip and truncates
        // unrecoverably ("...nts / Workspace"). Hide it on compact
        // width; the file tab pill itself shows the file name and
        // the user can see the full path in the Files browser.
        if isCompactWidth {
            breadcrumbLabel.isHidden = true
            return
        }
        breadcrumbLabel.isHidden = false
        let parentComponents = url.deletingLastPathComponent().pathComponents
        // Strip the leading "/" component on absolute paths so the
        // breadcrumb reads "workspaces / interpreter-lab / src" not
        // "/ workspaces / interpreter-lab / src".
        let useful = parentComponents.filter { $0 != "/" }
        let tail = useful.suffix(3)
        breadcrumbLabel.text = tail.joined(separator: " / ")
    }

    // MARK: - Setup AI Chat

    private func setupAIChat() {
        aiChatContainer.translatesAutoresizingMaskIntoConstraints = false
        aiChatContainer.backgroundColor = EditorTheme.chatBg
        aiChatContainer.layer.cornerRadius = 0
        aiChatContainer.clipsToBounds = true
        // Left border to separate from editor
        let chatBorder = UIView()
        chatBorder.backgroundColor = UIColor(white: 0.20, alpha: 0.6)
        chatBorder.translatesAutoresizingMaskIntoConstraints = false
        aiChatContainer.addSubview(chatBorder)
        NSLayoutConstraint.activate([
            chatBorder.topAnchor.constraint(equalTo: aiChatContainer.topAnchor),
            chatBorder.leadingAnchor.constraint(equalTo: aiChatContainer.leadingAnchor),
            chatBorder.bottomAnchor.constraint(equalTo: aiChatContainer.bottomAnchor),
            chatBorder.widthAnchor.constraint(equalToConstant: 0.5),
        ])

        // Title
        chatTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        chatTitleLabel.text = "AI Assistant"
        chatTitleLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        chatTitleLabel.textColor = EditorTheme.foreground

        // Model selector
        var modelConfig = UIButton.Configuration.tinted()
        modelConfig.title = "No Model"
        modelConfig.image = UIImage(systemName: "cpu")
        modelConfig.imagePadding = 4
        modelConfig.baseBackgroundColor = .systemPurple
        modelConfig.baseForegroundColor = .systemPurple
        modelConfig.cornerStyle = .capsule
        modelConfig.buttonSize = .small
        modelSelectorButton.configuration = modelConfig
        modelSelectorButton.translatesAutoresizingMaskIntoConstraints = false
        modelSelectorButton.showsMenuAsPrimaryAction = true
        modelSelectorButton.menu = buildModelMenu()

        // Chat scroll area
        chatScrollView.translatesAutoresizingMaskIntoConstraints = false
        chatScrollView.showsVerticalScrollIndicator = true
        chatScrollView.alwaysBounceVertical = true

        chatStackView.translatesAutoresizingMaskIntoConstraints = false
        chatStackView.axis = .vertical
        chatStackView.spacing = 8
        chatStackView.alignment = .fill
        chatScrollView.addSubview(chatStackView)

        // Input row
        chatInputField.translatesAutoresizingMaskIntoConstraints = false
        chatInputField.placeholder = "Ask about your code..."
        chatInputField.font = UIFont.systemFont(ofSize: 14)
        chatInputField.backgroundColor = EditorTheme.gutterBg
        chatInputField.textColor = EditorTheme.foreground
        chatInputField.layer.cornerRadius = 8
        chatInputField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        chatInputField.leftViewMode = .always
        chatInputField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        chatInputField.rightViewMode = .always
        chatInputField.keyboardAppearance = .dark
        chatInputField.returnKeyType = .send
        chatInputField.delegate = self

        var sendConfig = UIButton.Configuration.filled()
        sendConfig.image = UIImage(systemName: "arrow.up.circle.fill")
        sendConfig.baseBackgroundColor = .systemCyan
        sendConfig.baseForegroundColor = .white
        sendConfig.cornerStyle = .capsule
        sendConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        chatSendButton.configuration = sendConfig
        chatSendButton.addTarget(self, action: #selector(sendChatMessage), for: .touchUpInside)
        chatSendButton.translatesAutoresizingMaskIntoConstraints = false

        let inputRow = UIStackView(arrangedSubviews: [chatInputField, chatSendButton])
        inputRow.axis = .horizontal
        inputRow.spacing = 6
        inputRow.alignment = .center
        inputRow.translatesAutoresizingMaskIntoConstraints = false

        // Close (X) button — second way to dismiss the chat panel.
        let closeChatButton = UIButton(type: .system)
        var closeCfg = UIButton.Configuration.plain()
        closeCfg.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        )
        closeCfg.baseForegroundColor = EditorTheme.gutterText
        closeCfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        closeChatButton.configuration = closeCfg
        closeChatButton.addTarget(self, action: #selector(toggleAIChat), for: .touchUpInside)
        closeChatButton.translatesAutoresizingMaskIntoConstraints = false

        let chatHeaderRow = UIStackView(arrangedSubviews: [chatTitleLabel, modelSelectorButton, closeChatButton])
        chatHeaderRow.axis = .horizontal
        chatHeaderRow.spacing = 8
        chatHeaderRow.alignment = .center
        chatHeaderRow.translatesAutoresizingMaskIntoConstraints = false

        aiChatContainer.addSubview(chatHeaderRow)
        aiChatContainer.addSubview(chatScrollView)
        aiChatContainer.addSubview(inputRow)

        NSLayoutConstraint.activate([
            chatHeaderRow.topAnchor.constraint(equalTo: aiChatContainer.topAnchor, constant: 10),
            chatHeaderRow.leadingAnchor.constraint(equalTo: aiChatContainer.leadingAnchor, constant: 10),
            chatHeaderRow.trailingAnchor.constraint(equalTo: aiChatContainer.trailingAnchor, constant: -10),

            chatScrollView.topAnchor.constraint(equalTo: chatHeaderRow.bottomAnchor, constant: 8),
            chatScrollView.leadingAnchor.constraint(equalTo: aiChatContainer.leadingAnchor, constant: 8),
            chatScrollView.trailingAnchor.constraint(equalTo: aiChatContainer.trailingAnchor, constant: -8),
            chatScrollView.bottomAnchor.constraint(equalTo: inputRow.topAnchor, constant: -8),

            chatStackView.topAnchor.constraint(equalTo: chatScrollView.topAnchor),
            chatStackView.leadingAnchor.constraint(equalTo: chatScrollView.leadingAnchor),
            chatStackView.trailingAnchor.constraint(equalTo: chatScrollView.trailingAnchor),
            chatStackView.bottomAnchor.constraint(equalTo: chatScrollView.bottomAnchor),
            chatStackView.widthAnchor.constraint(equalTo: chatScrollView.widthAnchor),

            inputRow.leadingAnchor.constraint(equalTo: aiChatContainer.leadingAnchor, constant: 8),
            inputRow.trailingAnchor.constraint(equalTo: aiChatContainer.trailingAnchor, constant: -8),
            inputRow.bottomAnchor.constraint(equalTo: aiChatContainer.bottomAnchor, constant: -8),
            inputRow.heightAnchor.constraint(equalToConstant: 36),

            chatSendButton.widthAnchor.constraint(equalToConstant: 36),
            chatSendButton.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    // MARK: - Setup Output Panel

    private func setupOutputPanel() {
        outputPanel.translatesAutoresizingMaskIntoConstraints = false
        outputPanel.backgroundColor = EditorTheme.background  // Same as editor, not pure black
        outputPanel.layer.cornerRadius = 0
        outputPanel.clipsToBounds = true
        // Leading splitter — design CSS .ed-splitter:
        //   background    rgba(99,102,241,0.28)
        //   box-shadow    0 0 12px rgba(99,102,241,0.18) (indigo glow)
        // 1pt vertical with a soft halo so the editor + output read as
        // a single surface bisected by the splitter, not two pasted blocks.
        let outBorder = UIView()
        outBorder.backgroundColor = EditorTheme.accent.withAlphaComponent(0.28)
        outBorder.layer.shadowColor = EditorTheme.accent.cgColor
        outBorder.layer.shadowOpacity = 0.18
        outBorder.layer.shadowOffset = .zero
        outBorder.layer.shadowRadius = 6
        outBorder.layer.masksToBounds = false
        outBorder.translatesAutoresizingMaskIntoConstraints = false
        outputPanel.addSubview(outBorder)
        NSLayoutConstraint.activate([
            outBorder.topAnchor.constraint(equalTo: outputPanel.topAnchor),
            outBorder.leadingAnchor.constraint(equalTo: outputPanel.leadingAnchor),
            outBorder.bottomAnchor.constraint(equalTo: outputPanel.bottomAnchor),
            outBorder.widthAnchor.constraint(equalToConstant: 1),
        ])

        // Output panel header — matches editor header's 36pt baseline.
        // Design CSS .ed-output-header:
        //   bg     linear-gradient(180deg, #0e0e15 0%, var(--bg) 100%)
        //   border bottom 1px var(--border-sub)
        //   layout: [OUTPUT label] ……… [Console][Preview][Plots]
        outputHeaderBar.translatesAutoresizingMaskIntoConstraints = false
        outputHeaderBar.backgroundColor = .clear
        let outputHeaderGradient = CAGradientLayer()
        outputHeaderGradient.name = "cb.output.headerBg"
        outputHeaderGradient.colors = [
            UIColor(red: 0x0e/255.0, green: 0x0e/255.0, blue: 0x15/255.0, alpha: 1.0).cgColor,
            EditorTheme.background.cgColor,
        ]
        outputHeaderGradient.startPoint = CGPoint(x: 0.5, y: 0)
        outputHeaderGradient.endPoint = CGPoint(x: 0.5, y: 1)
        outputHeaderBar.layer.insertSublayer(outputHeaderGradient, at: 0)

        let outputHeaderBorder = UIView()
        outputHeaderBorder.translatesAutoresizingMaskIntoConstraints = false
        outputHeaderBorder.backgroundColor = EditorTheme.borderSub
        outputHeaderBar.addSubview(outputHeaderBorder)

        outputTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        outputTitleLabel.text = "OUTPUT"
        outputTitleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        outputTitleLabel.textColor = UIColor(red: 0x7e/255.0, green: 0x7e/255.0, blue: 0x92/255.0, alpha: 1.0)
        // CSS letter-spacing: 0.14em ≈ 1.5pt at 11pt font.
        outputTitleLabel.attributedText = NSAttributedString(
            string: "OUTPUT",
            attributes: [.kern: 1.5,
                         .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: UIColor(red: 0x7e/255.0, green: 0x7e/255.0, blue: 0x92/255.0, alpha: 1.0)])

        // Custom pill toggle (matches design .ed-seg). Three child buttons,
        // outer container chrome-2 bg + soft border + 7pt radius + 2pt
        // padding. Active button: indigo-tint bg + 1pt inset indigo border.
        outputTabsContainer.translatesAutoresizingMaskIntoConstraints = false
        outputTabsContainer.backgroundColor = UIColor(red: 0x15/255.0, green: 0x15/255.0, blue: 0x1f/255.0, alpha: 1.0)
        outputTabsContainer.layer.cornerRadius = 7
        outputTabsContainer.layer.cornerCurve = .continuous
        outputTabsContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.06).cgColor
        outputTabsContainer.layer.borderWidth = 1

        func configureOutputTab(_ button: UIButton, _ title: String, tag: Int) {
            var cfg = UIButton.Configuration.plain()
            var attr = AttributeContainer()
            attr.font = UIFont.systemFont(ofSize: 11, weight: .medium)
            cfg.attributedTitle = AttributedString(title, attributes: attr)
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 9, bottom: 0, trailing: 9)
            cfg.baseForegroundColor = UIColor(red: 0x8e/255.0, green: 0x8e/255.0, blue: 0xa2/255.0, alpha: 1.0)
            button.configuration = cfg
            button.translatesAutoresizingMaskIntoConstraints = false
            button.tag = tag
            button.layer.cornerRadius = 5
            button.layer.cornerCurve = .continuous
            button.layer.borderWidth = 1
            button.layer.borderColor = UIColor.clear.cgColor
            button.addTarget(self, action: #selector(outputTabTapped(_:)),
                             for: .touchUpInside)
        }
        configureOutputTab(outputTabConsole, "Console", tag: 0)
        configureOutputTab(outputTabPreview, "Preview", tag: 1)
        configureOutputTab(outputTabPlots,   "Plots",   tag: 2)

        // These three tabs are wired only to a visual selection state —
        // the actual content-switch (Console=stdout, Preview=webview,
        // Plots=image grid) was never implemented. Hide them entirely
        // until someone wires the content branches; leaving useless
        // tappable chrome on screen confuses users. The configuration
        // above is preserved so the wire-up can be revived later
        // without rebuilding the layout from scratch.
        outputTabsContainer.isHidden = true

        let outputTabsRow = UIStackView(arrangedSubviews: [outputTabConsole, outputTabPreview, outputTabPlots])
        outputTabsRow.translatesAutoresizingMaskIntoConstraints = false
        outputTabsRow.axis = .horizontal
        outputTabsRow.spacing = 2
        outputTabsRow.alignment = .center
        outputTabsContainer.addSubview(outputTabsRow)
        NSLayoutConstraint.activate([
            outputTabsRow.topAnchor.constraint(equalTo: outputTabsContainer.topAnchor, constant: 2),
            outputTabsRow.bottomAnchor.constraint(equalTo: outputTabsContainer.bottomAnchor, constant: -2),
            outputTabsRow.leadingAnchor.constraint(equalTo: outputTabsContainer.leadingAnchor, constant: 2),
            outputTabsRow.trailingAnchor.constraint(equalTo: outputTabsContainer.trailingAnchor, constant: -2),
            outputTabConsole.heightAnchor.constraint(equalToConstant: 20),
            outputTabPreview.heightAnchor.constraint(equalToConstant: 20),
            outputTabPlots.heightAnchor.constraint(equalToConstant: 20),
        ])
        applyOutputTabsSelection()

        outputHeaderBar.addSubview(outputTitleLabel)
        outputHeaderBar.addSubview(outputTabsContainer)
        outputPanel.addSubview(outputHeaderBar)

        // Reflow the gradient once the header has size; piggyback on the
        // viewDidLayoutSubviews update path by storing a reference.
        outputHeaderBar.layoutIfNeeded()

        // Register JS→Swift message handlers for video controls + the
        // clipboard bridge (copy buttons in the preview pane route
        // through navigator.clipboard.writeText / execCommand('copy'),
        // both polyfilled to post-message us; we write to UIPasteboard).
        outputWebView.configuration.userContentController.add(self, name: "saveVideo")
        outputWebView.configuration.userContentController.add(self, name: "shareVideo")
        outputWebView.configuration.userContentController.add(self, name: "clipboard")

        // Subtle indigo grid (32×32) behind the empty state. Design CSS:
        //   linear-gradient(to right,  rgba(99,102,241,0.035) 1px, transparent 1px),
        //   linear-gradient(to bottom, rgba(99,102,241,0.035) 1px, transparent 1px);
        //   background-size: 32px 32px;
        //   mask-image: radial-gradient(ellipse at center, black 35%, transparent 75%);
        // CALayer + pattern image gives us the same effect.
        let gridLayer = CALayer()
        gridLayer.name = "cb.output.grid"
        gridLayer.frame = outputPanel.bounds
        if let pattern = Self.makeOutputGridPattern() {
            gridLayer.backgroundColor = UIColor(patternImage: pattern).cgColor
        }
        // Radial mask — black @ 35%, transparent @ 75%. Use a CAGradientLayer
        // as the mask (radial via .radial type, iOS 14+).
        let mask = CAGradientLayer()
        mask.type = .radial
        mask.colors = [
            UIColor.black.cgColor,
            UIColor.black.cgColor,
            UIColor.black.withAlphaComponent(0).cgColor,
        ]
        mask.locations = [0.0, 0.35, 0.75]
        mask.startPoint = CGPoint(x: 0.5, y: 0.5)
        mask.endPoint = CGPoint(x: 1.0, y: 1.0)
        mask.frame = outputPanel.bounds
        gridLayer.mask = mask
        outputPanel.layer.insertSublayer(gridLayer, at: 0)
        outputPlaceholderGridLayer = gridLayer

        outputPanel.addSubview(outputPlaceholderLabel)
        outputPanel.addSubview(outputWebView)
        outputPanel.addSubview(outputImageView)
        outputPanel.addSubview(outputPDFView)
        outputPanel.addSubview(outputExpandButton)

        // Empty-state play-circle + bottom meta. Design CSS:
        //   .ed-playmark  28×28 round, 1pt indigo (rgba 99,102,241,0.35) border,
        //                 rgba(99,102,241,0.06) bg, indigo play icon
        //   .ed-output-meta  bottom-left mono 10.5pt color #4a4a5c
        outputPlaymark.translatesAutoresizingMaskIntoConstraints = false
        outputPlaymark.layer.cornerRadius = 14
        outputPlaymark.layer.cornerCurve = .continuous
        outputPlaymark.layer.borderColor = EditorTheme.accent.withAlphaComponent(0.35).cgColor
        outputPlaymark.layer.borderWidth = 1
        outputPlaymark.backgroundColor = EditorTheme.accent.withAlphaComponent(0.06)

        outputPlaymarkIcon.translatesAutoresizingMaskIntoConstraints = false
        outputPlaymarkIcon.image = UIImage(systemName: "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        outputPlaymarkIcon.tintColor = EditorTheme.accent
        outputPlaymark.addSubview(outputPlaymarkIcon)

        outputPanel.addSubview(outputPlaymark)

        outputMetaLabel.translatesAutoresizingMaskIntoConstraints = false
        outputMetaLabel.numberOfLines = 0
        outputMetaLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        // Match design — uppercase keys ("TARGET ▸ swift 5.10 · debug")
        // in #6e6e84, body in #4a4a5c.
        let metaKey = UIColor(red: 0x6e/255.0, green: 0x6e/255.0, blue: 0x84/255.0, alpha: 1.0)
        let metaTxt = UIColor(red: 0x4a/255.0, green: 0x4a/255.0, blue: 0x5c/255.0, alpha: 1.0)
        let metaMS = NSMutableAttributedString()
        metaMS.append(NSAttributedString(string: "target", attributes: [.foregroundColor: metaKey]))
        metaMS.append(NSAttributedString(string: " ▸ swift 5.10 · debug    ", attributes: [.foregroundColor: metaTxt]))
        metaMS.append(NSAttributedString(string: "device", attributes: [.foregroundColor: metaKey]))
        metaMS.append(NSAttributedString(string: " ▸ iPad simulator", attributes: [.foregroundColor: metaTxt]))
        outputMetaLabel.attributedText = metaMS
        outputPanel.addSubview(outputMetaLabel)

        // Initially hide everything except placeholder
        outputWebView.isHidden = true
        outputImageView.isHidden = true
        outputPDFView.isHidden = true

        outputExpandButton.addTarget(self, action: #selector(presentFullscreenPreview),
                                     for: .touchUpInside)

        NSLayoutConstraint.activate([
            // Output header bar — 36pt mirrors editorHeaderBar so the
            // editor + output baselines line up across the splitter.
            outputHeaderBar.topAnchor.constraint(equalTo: outputPanel.topAnchor),
            outputHeaderBar.leadingAnchor.constraint(equalTo: outputPanel.leadingAnchor, constant: 1),
            outputHeaderBar.trailingAnchor.constraint(equalTo: outputPanel.trailingAnchor),
            outputHeaderBar.heightAnchor.constraint(equalToConstant: 36),

            outputHeaderBorder.leadingAnchor.constraint(equalTo: outputHeaderBar.leadingAnchor),
            outputHeaderBorder.trailingAnchor.constraint(equalTo: outputHeaderBar.trailingAnchor),
            outputHeaderBorder.bottomAnchor.constraint(equalTo: outputHeaderBar.bottomAnchor),
            outputHeaderBorder.heightAnchor.constraint(equalToConstant: 0.5),

            outputTitleLabel.leadingAnchor.constraint(equalTo: outputHeaderBar.leadingAnchor, constant: 14),
            outputTitleLabel.centerYAnchor.constraint(equalTo: outputHeaderBar.centerYAnchor),

            outputTabsContainer.trailingAnchor.constraint(equalTo: outputHeaderBar.trailingAnchor, constant: -12),
            outputTabsContainer.centerYAnchor.constraint(equalTo: outputHeaderBar.centerYAnchor),
            outputTabsContainer.heightAnchor.constraint(equalToConstant: 24),

            // Output body — anchored below the new header. All content
            // surfaces (webview / image / PDF / placeholder) share this
            // anchor so they slot into the right spot under the tabs.
            outputWebView.topAnchor.constraint(equalTo: outputHeaderBar.bottomAnchor),
            outputWebView.leadingAnchor.constraint(equalTo: outputPanel.leadingAnchor, constant: 1),
            outputWebView.trailingAnchor.constraint(equalTo: outputPanel.trailingAnchor),
            outputWebView.bottomAnchor.constraint(equalTo: outputPanel.bottomAnchor),

            outputImageView.topAnchor.constraint(equalTo: outputHeaderBar.bottomAnchor, constant: 4),
            outputImageView.leadingAnchor.constraint(equalTo: outputPanel.leadingAnchor, constant: 5),
            outputImageView.trailingAnchor.constraint(equalTo: outputPanel.trailingAnchor, constant: -4),
            outputImageView.bottomAnchor.constraint(equalTo: outputPanel.bottomAnchor, constant: -4),

            outputPDFView.topAnchor.constraint(equalTo: outputHeaderBar.bottomAnchor, constant: 4),
            outputPDFView.leadingAnchor.constraint(equalTo: outputPanel.leadingAnchor, constant: 5),
            outputPDFView.trailingAnchor.constraint(equalTo: outputPanel.trailingAnchor, constant: -4),
            outputPDFView.bottomAnchor.constraint(equalTo: outputPanel.bottomAnchor, constant: -4),

            // Play-circle sits LEFT of the placeholder text, both
            // co-centered on the panel (.ed-empty layout).
            outputPlaymark.centerYAnchor.constraint(equalTo: outputPanel.centerYAnchor),
            outputPlaymark.widthAnchor.constraint(equalToConstant: 28),
            outputPlaymark.heightAnchor.constraint(equalToConstant: 28),
            outputPlaymarkIcon.centerXAnchor.constraint(equalTo: outputPlaymark.centerXAnchor),
            outputPlaymarkIcon.centerYAnchor.constraint(equalTo: outputPlaymark.centerYAnchor),
            outputPlaymarkIcon.widthAnchor.constraint(equalToConstant: 10),
            outputPlaymarkIcon.heightAnchor.constraint(equalToConstant: 10),

            outputPlaceholderLabel.leadingAnchor.constraint(equalTo: outputPlaymark.trailingAnchor, constant: 10),
            outputPlaceholderLabel.centerYAnchor.constraint(equalTo: outputPanel.centerYAnchor),

            // The play circle's centerX is laid out so the whole row
            // (mark + label) is visually centered in the panel.
            outputPlaymark.trailingAnchor.constraint(equalTo: outputPanel.centerXAnchor, constant: -4),

            // Bottom-left runtime meta — matches design .ed-output-meta.
            outputMetaLabel.leadingAnchor.constraint(equalTo: outputPanel.leadingAnchor, constant: 14),
            outputMetaLabel.bottomAnchor.constraint(equalTo: outputPanel.bottomAnchor, constant: -12),

            outputExpandButton.topAnchor.constraint(equalTo: outputHeaderBar.bottomAnchor, constant: 8),
            outputExpandButton.trailingAnchor.constraint(equalTo: outputPanel.trailingAnchor, constant: -8),
            outputExpandButton.widthAnchor.constraint(equalToConstant: 28),
            outputExpandButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    /// Generates a 32×32 indigo line-pattern image for the output panel
    /// empty state. Matches `background-image: linear-gradient(to right
    /// ...), linear-gradient(to bottom ...)` from design CSS — a 1pt
    /// vertical line on the right edge + 1pt horizontal line on the
    /// bottom edge, both at rgba(99,102,241,0.035).
    private static func makeOutputGridPattern() -> UIImage? {
        let size = CGSize(width: 32, height: 32)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.clear.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            cg.setStrokeColor(UIColor(red: 0x63/255.0, green: 0x66/255.0, blue: 0xf1/255.0, alpha: 0.035).cgColor)
            cg.setLineWidth(1)
            // Right edge
            cg.move(to: CGPoint(x: 31.5, y: 0))
            cg.addLine(to: CGPoint(x: 31.5, y: 32))
            // Bottom edge
            cg.move(to: CGPoint(x: 0, y: 31.5))
            cg.addLine(to: CGPoint(x: 32, y: 31.5))
            cg.strokePath()
        }
    }

    /// Output panel tab switcher. Today the tabs are visual chrome —
    /// the runner still routes to whichever surface (webView / image /
    /// PDF / placeholder) the run produced, regardless of which tab the
    /// user picked. Wiring this to actual content switches is a follow-
    /// up (Console = stdout log, Preview = webview, Plots = image grid).
    @objc private func outputTabTapped(_ sender: UIButton) {
        outputTabsSelectedIndex = sender.tag
        applyOutputTabsSelection()
    }

    /// Collapse / expand the editor's embedded files panel. Animates
    /// the width constant between 0 and 220pt and updates the toolbar
    /// icon to reflect the current state.
    @objc private func toggleEditorFilesPanel() {
        editorFilesPanelVisible.toggle()
        editorFilesWidthConstraint.constant = editorFilesPanelVisible ? 220 : 0
        // Flip the icon tint to signal state: bright accent when the
        // files panel is open, muted grey when collapsed. We keep the
        // same `sidebar.left` SF Symbol for both states (no `.fill`
        // variant exists on the iOS-17 deployment target).
        if var cfg = filesToggleButton.configuration {
            cfg.baseForegroundColor = editorFilesPanelVisible
                ? EditorTheme.accent
                : UIColor(white: 0.55, alpha: 1)
            filesToggleButton.configuration = cfg
        }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseInOut]) {
            self.editorFilesPanel.alpha = self.editorFilesPanelVisible ? 1 : 0
            self.view.layoutIfNeeded()
        }
    }

    /// Toggle the entire empty-state group (placeholder text + play
    /// circle + grid overlay + bottom meta line) in lockstep. Called
    /// in place of the legacy `outputPlaceholderLabel.isHidden = …`
    /// since the Claude Design merge added sibling components that
    /// should appear/disappear together.
    private func setOutputEmptyStateHidden(_ hidden: Bool) {
        outputPlaceholderLabel.isHidden = hidden
        outputPlaymark.isHidden = hidden
        outputMetaLabel.isHidden = hidden
        outputPlaceholderGridLayer?.isHidden = hidden
    }

    /// Repaint the active pill in the output panel's tab toggle.
    /// Active button gets indigo bg (rgba 99,102,241,0.16) + 1pt indigo
    /// border (0.28 alpha) + color #c7c9ff. Inactive: transparent bg,
    /// muted color #8e8ea2.
    private func applyOutputTabsSelection() {
        let activeBg     = EditorTheme.accent.withAlphaComponent(0.16)
        let activeBorder = EditorTheme.accent.withAlphaComponent(0.28).cgColor
        let activeFg     = UIColor(red: 0xc7/255.0, green: 0xc9/255.0, blue: 0xff/255.0, alpha: 1.0)
        let mutedFg      = UIColor(red: 0x8e/255.0, green: 0x8e/255.0, blue: 0xa2/255.0, alpha: 1.0)
        for (i, button) in [outputTabConsole, outputTabPreview, outputTabPlots].enumerated() {
            let isOn = (i == outputTabsSelectedIndex)
            button.backgroundColor = isOn ? activeBg : .clear
            button.layer.borderColor = isOn ? activeBorder : UIColor.clear.cgColor
            var cfg = button.configuration ?? UIButton.Configuration.plain()
            cfg.baseForegroundColor = isOn ? activeFg : mutedFg
            button.configuration = cfg
        }
    }

    @objc private func presentFullscreenPreview() {
        guard let path = currentOutputPath else { return }
        // Live URLs (pywebview pages) need to skip the file-existence
        // check — that test always failed for "https://..." paths so
        // tapping the expand button on a webview preview did nothing.
        let isURL = path.hasPrefix("http://") || path.hasPrefix("https://")
        if !isURL && !FileManager.default.fileExists(atPath: path) {
            return
        }
        let vc = PreviewFullscreenViewController(path: path)
        present(vc, animated: true)
    }

    // MARK: - Setup Terminal

    private func setupTerminal() {
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.backgroundColor = EditorTheme.terminalBg
        terminalContainer.layer.cornerRadius = 8
        terminalContainer.clipsToBounds = true

        // Drag handle for resizing — tucked at the very top of the bar
        terminalDragHandle.translatesAutoresizingMaskIntoConstraints = false
        terminalDragHandle.backgroundColor = EditorTheme.gutterText.withAlphaComponent(0.3)
        terminalDragHandle.layer.cornerRadius = 2

        // Title bar — Claude Design slim 22pt strip. Design CSS .ed-term-head:
        //   bg     #0c0c13 (a touch darker than gutterBg so it reads as
        //          a separator from the editor body above)
        //   border bottom 1px rgba(255,255,255,0.03)
        terminalTitleBar.translatesAutoresizingMaskIntoConstraints = false
        terminalTitleBar.backgroundColor = UIColor(red: 0x0c/255.0, green: 0x0c/255.0, blue: 0x13/255.0, alpha: 1.0)

        // Functional traffic lights. Close hides the terminal pane entirely,
        // Minimize shrinks it to just the title bar, Maximize expands to
        // ~70% of the available screen height.
        func makeTrafficLight(_ button: UIButton, color: UIColor, glyph: String) {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.backgroundColor = color
            button.layer.cornerRadius = 6
            button.tintColor = UIColor(white: 0.12, alpha: 1)
            button.setTitle("", for: .normal)
            // Priority 999 (just below required) so the 0-width temporary
            // layout pass doesn't fight us — UIKit logs constraint conflicts
            // when a parent's _UITemporaryLayoutWidth=0 contradicts a 12pt
            // child width. With 999 the temporary pass wins gracefully.
            let bw = button.widthAnchor.constraint(equalToConstant: 12)
            let bh = button.heightAnchor.constraint(equalToConstant: 12)
            bw.priority = .init(999); bh.priority = .init(999)
            bw.isActive = true; bh.isActive = true
            // Add an SF-Symbols glyph that only shows on hover/press (iOS
            // can't do hover, so we show it always, but small).
            let cfg = UIImage.SymbolConfiguration(pointSize: 8, weight: .heavy)
            button.setImage(UIImage(systemName: glyph, withConfiguration: cfg)?
                            .withTintColor(UIColor(white: 0.12, alpha: 1), renderingMode: .alwaysOriginal),
                            for: .normal)
            button.imageView?.contentMode = .scaleAspectFit
        }
        // Mac-style traffic lights — but only the useful two:
        // minimize (yellow) collapses the terminal pane, maximize
        // (green) expands it. The close (red) light has been
        // removed — closing the terminal entirely had no path back
        // and was reported as useless.
        makeTrafficLight(terminalTrafficMin,   color: UIColor(red: 1.00, green: 0.75, blue: 0.20, alpha: 1), glyph: "minus")
        makeTrafficLight(terminalTrafficMax,   color: UIColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1), glyph: "arrow.up.left.and.arrow.down.right")
        terminalTrafficMin.addTarget(self,   action: #selector(terminalMinimize), for: .touchUpInside)
        terminalTrafficMax.addTarget(self,   action: #selector(terminalMaximize), for: .touchUpInside)
        // Hide the close traffic light's instance so any old constraint
        // referencing it doesn't dangle. Could be removed entirely once
        // we're sure nothing else references the field.
        terminalTrafficClose.isHidden = true

        let trafficLights = UIStackView(arrangedSubviews: [terminalTrafficMin, terminalTrafficMax])
        trafficLights.translatesAutoresizingMaskIntoConstraints = false
        trafficLights.axis = .horizontal
        trafficLights.spacing = 8

        // Center title — follows macOS Terminal.app convention:
        //   "<user> — <shell> — <cols>×<rows>"
        // e.g. "CodeBench — python3.14 — 120×30"
        terminalTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        terminalTitleLabel.text = "CodeBench — python3.14 — 80×24"
        terminalTitleLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminalTitleLabel.textColor = UIColor(white: 0.82, alpha: 1)
        terminalTitleLabel.textAlignment = .center
        terminalTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Colored status dot + label — flips color with TerminalStatus
        terminalStatusDot.translatesAutoresizingMaskIntoConstraints = false
        terminalStatusDot.backgroundColor = TerminalStatus.ready.color
        terminalStatusDot.layer.cornerRadius = 4

        terminalStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        terminalStatusLabel.text = "ready"
        terminalStatusLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        terminalStatusLabel.textColor = TerminalStatus.ready.color

        // Spinner, shown while code runs
        terminalSpinner.translatesAutoresizingMaskIntoConstraints = false
        terminalSpinner.color = UIColor(white: 0.7, alpha: 1)
        terminalSpinner.hidesWhenStopped = true

        // Right-side controls — pruned to the three useful actions:
        // Stop (sends Ctrl+C / SIGINT to the running process), Copy
        // (copies the visible terminal buffer), and Clear. The
        // previous "..." menu, font +/− steppers, and the Mac-style
        // close/min/max traffic lights were removed — they took
        // visual space without adding capability the user reaches
        // for. Font size is still adjustable via Settings popover.

        func makeTerminalIconButton(_ button: UIButton, systemName: String, tint: UIColor = UIColor(white: 0.7, alpha: 1), action: Selector) {
            button.translatesAutoresizingMaskIntoConstraints = false
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: systemName,
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
            cfg.baseForegroundColor = tint
            button.configuration = cfg
            button.addTarget(self, action: action, for: .touchUpInside)
        }

        // Emergency stop — a clearly-labeled Ctrl+C button. Tinted
        // .filled with red bg + "Stop" label so the user can spot it
        // instantly when something runs away. Sends SIGINT to the
        // Python REPL via PTYBridge.
        var stopCfg = UIButton.Configuration.tinted()
        stopCfg.image = UIImage(systemName: "xmark.octagon.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        var stopAttr = AttributeContainer()
        stopAttr.font = UIFont.systemFont(ofSize: 11, weight: .semibold).rounded
        stopCfg.attributedTitle = AttributedString("Stop", attributes: stopAttr)
        stopCfg.imagePadding = 4
        stopCfg.baseForegroundColor = UIColor(red: 1.0, green: 0.40, blue: 0.40, alpha: 1.0)
        stopCfg.baseBackgroundColor = UIColor(red: 1.0, green: 0.40, blue: 0.40, alpha: 1.0)
        stopCfg.cornerStyle = .capsule
        stopCfg.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        terminalInterruptButton.configuration = stopCfg
        terminalInterruptButton.translatesAutoresizingMaskIntoConstraints = false
        terminalInterruptButton.addTarget(self, action: #selector(terminalInterrupt), for: .touchUpInside)
        terminalInterruptButton.isPointerInteractionEnabled = true

        makeTerminalIconButton(terminalCopyButton, systemName: "doc.on.doc",
                               action: #selector(copyTerminalContents))
        makeTerminalIconButton(terminalClearButton, systemName: "trash",
                               action: #selector(clearTerminal))

        let rightControls = UIStackView(arrangedSubviews: [
            terminalInterruptButton,
            terminalCopyButton,
            terminalClearButton,
        ])
        rightControls.translatesAutoresizingMaskIntoConstraints = false
        rightControls.axis = .horizontal
        rightControls.spacing = 8
        rightControls.alignment = .center

        // Status cluster in the center/left
        let statusCluster = UIStackView(arrangedSubviews: [terminalStatusDot, terminalStatusLabel, terminalSpinner])
        statusCluster.translatesAutoresizingMaskIntoConstraints = false
        statusCluster.axis = .horizontal
        statusCluster.spacing = 5
        statusCluster.alignment = .center

        // Claude Design slim-strip terminal title — replaces the
        // Mac-Terminal "traffic lights + centered title" look. The new
        // strip reads as one informational line:
        //   [● workspace] [interpreter-lab] [· zsh · 80×24] [· 2 sessions] ... [~/src] [⌄]  [stop][copy][clear]
        // The legacy traffic-light buttons (terminalTrafficMin/Max) and
        // the giant terminalTitleLabel stay allocated so any other code
        // that pokes them keeps compiling, but they're no longer mounted
        // in the bar — the slim row owns the layout.
        trafficLights.isHidden = true
        terminalTitleLabel.isHidden = true
        statusCluster.isHidden = true

        // Workspace swatch — design CSS .ed-ws .swatch:
        //   8×8 with linear-gradient(135deg, var(--indigo), var(--violet))
        //   border-radius 2 (square-with-soft-corners, NOT a round dot)
        termWorkspaceDot.translatesAutoresizingMaskIntoConstraints = false
        termWorkspaceDot.backgroundColor = .clear
        termWorkspaceDot.layer.cornerRadius = 2
        termWorkspaceDot.layer.cornerCurve = .continuous
        let swatchGradient = CAGradientLayer()
        swatchGradient.name = "cb.term.swatch"
        swatchGradient.colors = [EditorTheme.accent.cgColor, EditorTheme.accentViolet.cgColor]
        swatchGradient.startPoint = CGPoint(x: 0, y: 0)
        swatchGradient.endPoint = CGPoint(x: 1, y: 1)
        swatchGradient.cornerRadius = 2
        swatchGradient.frame = CGRect(x: 0, y: 0, width: 8, height: 8)
        termWorkspaceDot.layer.insertSublayer(swatchGradient, at: 0)

        termWorkspaceNameLabel.translatesAutoresizingMaskIntoConstraints = false
        termWorkspaceNameLabel.text = "interpreter-lab"
        termWorkspaceNameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        termWorkspaceNameLabel.textColor = UIColor(white: 0.88, alpha: 1)

        termMetaLabel.translatesAutoresizingMaskIntoConstraints = false
        termMetaLabel.text = "· zsh · 80×24"
        termMetaLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        termMetaLabel.textColor = UIColor(white: 0.52, alpha: 1)

        termSessionsLabel.translatesAutoresizingMaskIntoConstraints = false
        termSessionsLabel.text = "· 1 session"
        termSessionsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        termSessionsLabel.textColor = UIColor(white: 0.42, alpha: 1)

        termPathPill.translatesAutoresizingMaskIntoConstraints = false
        termPathPill.text = "  ~  "
        termPathPill.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        termPathPill.textColor = EditorTheme.accent
        termPathPill.backgroundColor = EditorTheme.accent.withAlphaComponent(0.10)
        termPathPill.layer.cornerRadius = 4
        termPathPill.layer.cornerCurve = .continuous
        termPathPill.layer.borderColor = EditorTheme.accent.withAlphaComponent(0.25).cgColor
        termPathPill.layer.borderWidth = 0.5
        termPathPill.clipsToBounds = true

        // Collapse chevron — functionally the same as the old yellow
        // minimize traffic light, but as a quiet glyph in the strip.
        var collapseCfg = UIButton.Configuration.plain()
        collapseCfg.image = UIImage(systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        collapseCfg.baseForegroundColor = UIColor(white: 0.55, alpha: 1)
        collapseCfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        termCollapseChevron.configuration = collapseCfg
        termCollapseChevron.translatesAutoresizingMaskIntoConstraints = false
        termCollapseChevron.addTarget(self, action: #selector(terminalMinimize), for: .touchUpInside)
        termCollapseChevron.isPointerInteractionEnabled = true

        // Left cluster — fixed-position metadata.
        let leftSlim = UIStackView(arrangedSubviews: [
            termWorkspaceDot,
            termWorkspaceNameLabel,
            termMetaLabel,
            termSessionsLabel,
        ])
        leftSlim.translatesAutoresizingMaskIntoConstraints = false
        leftSlim.axis = .horizontal
        leftSlim.spacing = 6
        leftSlim.alignment = .center

        terminalTitleBar.addSubview(terminalDragHandle)
        terminalTitleBar.addSubview(leftSlim)
        terminalTitleBar.addSubview(termPathPill)
        terminalTitleBar.addSubview(termCollapseChevron)
        terminalTitleBar.addSubview(rightControls)

        // iPhone (compact width): hide the lower-priority metadata
        // pieces that cause the title bar to overflow. Without this,
        // the rightControls' "Stop" button sits visually on top of
        // termSessionsLabel ("· 1 session" — the user reports this
        // as "Stop button overlapping Session text"). Stack views
        // collapse hidden subviews, so this actually frees layout
        // space rather than just making them invisible.
        if isCompactWidth {
            termMetaLabel.isHidden = true        // "· zsh · 80×24"
            termSessionsLabel.isHidden = true    // "· 1 session"
            termPathPill.isHidden = true         // " ~ " pill — rarely useful on iPhone
            terminalCopyButton.isHidden = true   // copy button → long-press terminal instead
            terminalClearButton.isHidden = true  // clear → use `clear` command
        }

        // Terminal output — SwiftTerm xterm emulator backed by the shared PTY.
        // Use SF Mono explicitly and a slightly larger default (14pt) since
        // iPhone screens make 13pt look cramped.
        if terminalFontSize == 13 { terminalFontSize = 14 }
        let font = UIFont(name: "SFMono-Regular", size: terminalFontSize)
            ?? UIFont.monospacedSystemFont(ofSize: terminalFontSize, weight: .regular)
        swiftTermView.font = font
        swiftTermView.backgroundColor = EditorTheme.terminalBg

        // Remove SwiftTerm's default ESC/F1-F12 accessory bar. It's
        // useless when a Magic Keyboard is attached (those keys are
        // already physically available), and on soft-keyboard-only
        // sessions it eats vertical space without offering anything
        // our users reach for often. We'll re-add a minimal toolbar
        // that only shows when NO magic keyboard is present.
        swiftTermView.inputAccessoryView = nil
        updateTerminalAccessoryForKeyboardState()
        NotificationCenter.default.addObserver(self,
            selector: #selector(updateTerminalAccessoryForKeyboardState),
            name: .GCKeyboardDidConnect, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(updateTerminalAccessoryForKeyboardState),
            name: .GCKeyboardDidDisconnect, object: nil)

        configureTerminalAppearance()

        swiftTermView.terminalDelegate = PTYBridge.shared
        PTYBridge.shared.terminalView = swiftTermView
        // Mirror every byte the PTY feeds into SwiftTerm into our
        // `terminalLogBuffer` so the Copy and Export-log buttons still
        // grab the full scrollback even though Python output now
        // bypasses appendToTerminal.
        PTYBridge.shared.onOutputBytes = { [weak self] bytes in
            guard let self = self else { return }
            if let s = String(bytes: bytes, encoding: .utf8) {
                self.terminalLogBuffer.append(s)
                if self.terminalLogBuffer.count > 1_000_000 {
                    let cut = self.terminalLogBuffer.index(
                        self.terminalLogBuffer.startIndex,
                        offsetBy: self.terminalLogBuffer.count / 2)
                    self.terminalLogBuffer = String(self.terminalLogBuffer[cut...])
                }
                // Watch for "[plot saved] <path>" lines from scripts
                // launched in the terminal (e.g. `python 3d.py`). The
                // Run-button path reads __codebench_plot_path from
                // Python globals; the terminal path doesn't, so we
                // surface the chart by scanning stdout instead.
                self.scanTerminalChunkForPlot(s)
            }
        }
        // Open the PTY master/slave pair eagerly, the moment the
        // terminal view exists — NOT on first Python run. Otherwise
        // anything the user types into the terminal before they hit
        // Run ends up as "send dropped: masterFD=-1 bytes=N" because
        // openpty() hasn't run yet. After this call, masterFD is a
        // live file descriptor and keystrokes flow into Python's stdin
        // the instant the REPL thread starts reading.
        PTYBridge.shared.setupIfNeeded()
        // Safety net for terminal-launched scripts: watch ToolOutputs/
        // for new chart files. The PTY scanner catches the
        // [plot saved] stdout line for most runs, but if the script
        // dies right after print (no trailing newline reaches us, or
        // stdout is buffered elsewhere) the dir-watch fallback still
        // brings the chart into the preview WebView.
        startToolOutputDirectoryWatcher()
        // Eagerly boot Python + start the REPL thread in the background
        // so that when the user types `ls` + Enter into the terminal
        // BEFORE tapping Run, there's a reader on the other side of
        // the pipe ready to dispatch. Without this, Enter submits the
        // line and nothing happens because no REPL thread exists yet.
        PythonRuntime.shared.ensureRuntimeReady()
        // Note: setTerminalInitialBanner is deferred to
        // viewDidLayoutSubviews (first pass only). Calling it here,
        // before the SwiftTerm view has a frame, makes SwiftTerm
        // render the prompt at its default 2-col fallback because
        // cols = max(2, width/charWidth) and width is 0. The deferred
        // call ensures the terminal has been sized first so the prompt
        // wraps at the real column count.

        // Tap-to-focus: on iPhone especially, the initial becomeFirstResponder
        // can silently lose to another view. Install a lightweight tap gesture
        // that forcibly hands focus back to the terminal.
        let tap = UITapGestureRecognizer(target: self, action: #selector(focusTerminal))
        tap.cancelsTouchesInView = false
        // Don't compete with SwiftTerm's own long-press / drag gestures
        // (text selection + iOS-standard tap-hold-drag cursor). Our tap
        // only fires on a fast single touch; the user's long-press +
        // drag to select text still reaches SwiftTerm unimpeded.
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.requiresExclusiveTouchType = false
        if let selectionDelegate = tap as? UIGestureRecognizerDelegate {
            _ = selectionDelegate  // quiet unused-var warning
        }
        tap.delegate = self
        swiftTermView.addGestureRecognizer(tap)

        // Cursor-drag-to-select: a UIPanGestureRecognizer that fires
        // SwiftTerm's selection logic the moment the user starts
        // dragging (instead of requiring a long-press first). On
        // .began, we synthesize a fake doubleTap to seed an initial
        // word selection at the touch point AND call SwiftTerm's
        // internal pan handler so subsequent movement extends it.
        //
        // Why pan, not LP: long-press makes the user wait — pan
        // fires immediately on first movement, which is what the
        // user expects (matches every other iOS text view).
        //
        // Critical: TerminalView IS a UIScrollView. Its built-in
        // panGestureRecognizer would normally claim every single-
        // finger touch for scrolling, and our pan would never fire.
        // We push scrolling to two-finger so single-finger drag is
        // available for selection. Scrollback is still reachable
        // with a two-finger drag.
        swiftTermView.panGestureRecognizer.minimumNumberOfTouches = 2
        swiftTermView.panGestureRecognizer.maximumNumberOfTouches = 2

        let dragSelect = UIPanGestureRecognizer(
            target: self, action: #selector(swiftTermDragSelectPan(_:)))
        dragSelect.minimumNumberOfTouches = 1
        dragSelect.maximumNumberOfTouches = 1
        dragSelect.delegate = self
        swiftTermView.addGestureRecognizer(dragSelect)

        // Trim SwiftTerm's stock long-press (context menu) so it
        // doesn't compete: 0.7 s default → 0.5 s.
        for gr in swiftTermView.gestureRecognizers ?? [] {
            if let lp = gr as? UILongPressGestureRecognizer,
               lp.minimumPressDuration >= 0.6 {
                lp.minimumPressDuration = 0.5
                break
            }
        }

        // Show the I-beam cursor on Mac Catalyst / iPad Pro with
        // trackpad when hovering over terminal text. SwiftTerm
        // doesn't install its own pointer interaction; without this
        // the default arrow shows which makes text look unselectable
        // even when it is.
        if #available(iOS 13.4, macCatalyst 13.4, *) {
            let pointer = UIPointerInteraction(delegate: self)
            swiftTermView.addInteraction(pointer)
        }
        // Also enable the double-click-to-select-word / triple-click-
        // to-select-line gestures Mac users expect, layered on top of
        // SwiftTerm's existing gestures without taking over the
        // first-click-drag path.
        let doubleTap = UITapGestureRecognizer(target: self,
            action: #selector(terminalDoubleTapSelect(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        swiftTermView.addGestureRecognizer(doubleTap)

        terminalContainer.addSubview(terminalTitleBar)
        terminalContainer.addSubview(swiftTermView)
        // No separate input bar — SwiftTerm receives keystrokes directly
        // and a Python REPL running on a background thread reads them
        // from PTY stdin, producing output via PTY stdout which SwiftTerm
        // then renders. Just like a real Terminal.app window.

        NSLayoutConstraint.activate([
            terminalTitleBar.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            terminalTitleBar.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            terminalTitleBar.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            terminalTitleBar.heightAnchor.constraint(equalToConstant: 22),

            // Drag handle becomes a near-invisible 1pt strip at the top
            // of the 22pt strip so the bar reads as a single slim line.
            terminalDragHandle.centerXAnchor.constraint(equalTo: terminalTitleBar.centerXAnchor),
            terminalDragHandle.topAnchor.constraint(equalTo: terminalTitleBar.topAnchor),
            terminalDragHandle.widthAnchor.constraint(equalToConstant: 36),
            terminalDragHandle.heightAnchor.constraint(equalToConstant: 2),

            // Fixed-size legacy status dot — kept allocated for any code
            // that pokes its color/visibility, but it's not in the bar.
            terminalStatusDot.widthAnchor.constraint(equalToConstant: 8),
            terminalStatusDot.heightAnchor.constraint(equalToConstant: 8),

            // ── Slim Claude Design strip ──
            termWorkspaceDot.widthAnchor.constraint(equalToConstant: 7),
            termWorkspaceDot.heightAnchor.constraint(equalToConstant: 7),

            leftSlim.leadingAnchor.constraint(equalTo: terminalTitleBar.leadingAnchor, constant: 12),
            leftSlim.centerYAnchor.constraint(equalTo: terminalTitleBar.centerYAnchor),

            termPathPill.trailingAnchor.constraint(equalTo: termCollapseChevron.leadingAnchor, constant: -8),
            termPathPill.centerYAnchor.constraint(equalTo: terminalTitleBar.centerYAnchor),
            termPathPill.heightAnchor.constraint(equalToConstant: 16),

            termCollapseChevron.trailingAnchor.constraint(equalTo: rightControls.leadingAnchor, constant: -4),
            termCollapseChevron.centerYAnchor.constraint(equalTo: terminalTitleBar.centerYAnchor),
            termCollapseChevron.widthAnchor.constraint(equalToConstant: 26),
            termCollapseChevron.heightAnchor.constraint(equalToConstant: 22),

            rightControls.trailingAnchor.constraint(equalTo: terminalTitleBar.trailingAnchor, constant: -6),
            rightControls.centerYAnchor.constraint(equalTo: terminalTitleBar.centerYAnchor),
            rightControls.heightAnchor.constraint(equalToConstant: 22),

            // SwiftTerm fills the whole pane below the title bar — no
            // separate input row. Tap into it and the keyboard pops up;
            // every keystroke is written to the PTY master which the
            // background Python REPL is reading.
            swiftTermView.topAnchor.constraint(equalTo: terminalTitleBar.bottomAnchor),
            swiftTermView.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            swiftTermView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            swiftTermView.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
        ])

        // Pan gesture for resizing
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTerminalDrag(_:)))
        terminalTitleBar.addGestureRecognizer(pan)
    }

    // MARK: - Terminal input bar

    private func buildTerminalInputBar() -> UIView {
        terminalInputBar.translatesAutoresizingMaskIntoConstraints = false
        terminalInputBar.backgroundColor = UIColor(red: 0.035, green: 0.040, blue: 0.052, alpha: 1.0)

        // Thin divider line on top
        let divider = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = UIColor(white: 0.14, alpha: 1)
        terminalInputBar.addSubview(divider)

        // Prompt label — updated by refreshPrompt() from Python's offlinai_shell.prompt()
        terminalPromptLabel.translatesAutoresizingMaskIntoConstraints = false
        terminalPromptLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        terminalPromptLabel.textColor = UIColor(red: 0.40, green: 0.87, blue: 0.49, alpha: 1)
        terminalPromptLabel.text = "$"
        terminalPromptLabel.setContentHuggingPriority(.required, for: .horizontal)
        terminalInputBar.addSubview(terminalPromptLabel)

        // Text field
        terminalInputField.translatesAutoresizingMaskIntoConstraints = false
        terminalInputField.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalInputField.textColor = UIColor(white: 0.95, alpha: 1)
        terminalInputField.backgroundColor = .clear
        terminalInputField.autocapitalizationType = .none
        terminalInputField.autocorrectionType = .no
        terminalInputField.spellCheckingType = .no
        terminalInputField.smartQuotesType = .no
        terminalInputField.smartDashesType = .no
        terminalInputField.returnKeyType = .send
        terminalInputField.keyboardType = .asciiCapable
        terminalInputField.delegate = self
        terminalInputField.attributedPlaceholder = NSAttributedString(
            string: "type 'help' for commands · Python works too",
            attributes: [.foregroundColor: UIColor(white: 0.35, alpha: 1)])
        terminalInputField.addTarget(self, action: #selector(terminalInputSubmitted), for: .editingDidEndOnExit)
        terminalInputField.onHistoryUp = { [weak self] in self?.historyPrevious() }
        terminalInputField.onHistoryDown = { [weak self] in self?.historyNext() }
        terminalInputBar.addSubview(terminalInputField)

        // Send button
        terminalSendButton.translatesAutoresizingMaskIntoConstraints = false
        var sendCfg = UIButton.Configuration.plain()
        sendCfg.image = UIImage(systemName: "return",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        sendCfg.baseForegroundColor = UIColor(red: 0.467, green: 0.729, blue: 1.000, alpha: 1)
        sendCfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 10)
        terminalSendButton.configuration = sendCfg
        terminalSendButton.addTarget(self, action: #selector(terminalInputSubmitted), for: .touchUpInside)
        terminalInputBar.addSubview(terminalSendButton)

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: terminalInputBar.topAnchor),
            divider.leadingAnchor.constraint(equalTo: terminalInputBar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: terminalInputBar.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 0.5),

            terminalPromptLabel.leadingAnchor.constraint(equalTo: terminalInputBar.leadingAnchor, constant: 10),
            terminalPromptLabel.centerYAnchor.constraint(equalTo: terminalInputBar.centerYAnchor),

            terminalInputField.leadingAnchor.constraint(equalTo: terminalPromptLabel.trailingAnchor, constant: 8),
            terminalInputField.trailingAnchor.constraint(equalTo: terminalSendButton.leadingAnchor),
            terminalInputField.topAnchor.constraint(equalTo: terminalInputBar.topAnchor),
            terminalInputField.bottomAnchor.constraint(equalTo: terminalInputBar.bottomAnchor),

            terminalSendButton.trailingAnchor.constraint(equalTo: terminalInputBar.trailingAnchor, constant: -4),
            terminalSendButton.centerYAnchor.constraint(equalTo: terminalInputBar.centerYAnchor),
            terminalSendButton.heightAnchor.constraint(equalToConstant: 32),
        ])
        return terminalInputBar
    }

    @objc private func terminalInputSubmitted() {
        let raw = terminalInputField.text ?? ""
        let line = raw  // keep indentation + whitespace
        terminalInputField.text = ""

        // Echo the typed line into the text view (with prompt prefix)
        let prompt = terminalContinuation ? "... " : terminalPromptLabel.text.map { "\($0) " } ?? "$ "
        appendToTerminal(prompt, isError: false)
        appendToTerminal(line + "\n", isError: false)

        if !line.isEmpty && !terminalContinuation {
            // Remember in history; skip duplicates of the last entry
            if terminalHistory.last != line { terminalHistory.append(line) }
            terminalHistoryIndex = terminalHistory.count
        }

        // Dispatch into the Python shell emulator. Running on a
        // background thread so the UI stays responsive for long ops.
        setTerminalStatus(.running)
        runShellLine(line) { [weak self] in
            self?.setTerminalStatus(.ready)
            self?.refreshTerminalPrompt()
        }
    }

    /// Run one line through offlinai_shell.run_line() and stream output.
    private func runShellLine(_ line: String, completion: @escaping () -> Void) {
        // Escape for Python: raw-triple-quoted won't handle every edge,
        // so round-trip through a base64-encoded bytes literal.
        let data = line.data(using: .utf8) ?? Data()
        let b64 = data.base64EncodedString()
        let pyCode = """
import base64, sys
_ensure = globals().get('_offlinai_shell_loaded', False)
if not _ensure:
    try:
        import offlinai_shell
        globals()['_offlinai_shell'] = offlinai_shell
        globals()['_offlinai_shell_loaded'] = True
    except Exception as _e:
        print(f'[shell] failed to load offlinai_shell: {_e}')
        raise
_line = base64.b64decode('\(b64)').decode('utf-8')
try:
    _offlinai_shell.run_line(_line)
except SystemExit as e:
    pass
finally:
    sys.stdout.flush()
    sys.stderr.flush()
    # Signal to Swift whether the shell is in continuation mode
    print('\\x1eSHELL-STATE:' + ('CONT' if _offlinai_shell.pending_continuation() else 'READY') + '\\x1e', end='')
"""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = PythonRuntime.shared.execute(code: pyCode) { chunk in
                DispatchQueue.main.async {
                    let cleaned = self?.extractShellState(from: chunk) ?? chunk
                    if !cleaned.isEmpty {
                        self?.appendToTerminal(cleaned, isError: false)
                    }
                }
            }
            DispatchQueue.main.async { completion() }
        }
    }

    /// Extract any `\x1eSHELL-STATE:…\x1e` sentinels from a streamed chunk
    /// and update `terminalContinuation`. Returns the chunk with sentinels removed.
    private func extractShellState(from chunk: String) -> String {
        var text = chunk
        while let start = text.range(of: "\u{1e}SHELL-STATE:") {
            if let endDelim = text.range(of: "\u{1e}", range: start.upperBound..<text.endIndex) {
                let state = String(text[start.upperBound..<endDelim.lowerBound])
                terminalContinuation = (state == "CONT")
                text.removeSubrange(start.lowerBound..<endDelim.upperBound)
            } else {
                break
            }
        }
        return text
    }

    /// Re-query the shell for its current PS1 and update the prompt label.
    private func refreshTerminalPrompt() {
        let pyCode = """
try:
    import offlinai_shell
    _p = offlinai_shell.ps2() if offlinai_shell.pending_continuation() else offlinai_shell.prompt()
    import sys
    sys.stdout.write('\\x1ePROMPT:' + _p + '\\x1e')
    sys.stdout.flush()
except Exception:
    pass
"""
        var captured = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = PythonRuntime.shared.execute(code: pyCode) { chunk in
                captured += chunk
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let start = captured.range(of: "\u{1e}PROMPT:"),
                   let end = captured.range(of: "\u{1e}", range: start.upperBound..<captured.endIndex) {
                    let prompt = String(captured[start.upperBound..<end.lowerBound])
                    // Strip ANSI — the label doesn't render colors
                    let clean = prompt.replacingOccurrences(of: "\u{1b}\\[[0-9;]*m",
                                                            with: "",
                                                            options: .regularExpression)
                    self.terminalPromptLabel.text = clean.trimmingCharacters(in: .whitespaces)
                    // Color the prompt label with ready/continuation color
                    self.terminalPromptLabel.textColor = self.terminalContinuation
                        ? UIColor(white: 0.5, alpha: 1)
                        : UIColor(red: 0.40, green: 0.87, blue: 0.49, alpha: 1)

                    // Also update the center title with a shorter "cwd — shell"
                    // so users can see where they are without reading the prompt.
                    let cwd = clean.components(separatedBy: " ").dropFirst().first ?? "~"
                    self.terminalTitleLabel.text = "Terminal — \(cwd)"
                }
            }
        }
    }

    // MARK: - History navigation
    private func historyPrevious() {
        guard !terminalHistory.isEmpty else { return }
        terminalHistoryIndex = max(0, terminalHistoryIndex - 1)
        if terminalHistoryIndex < terminalHistory.count {
            terminalInputField.text = terminalHistory[terminalHistoryIndex]
        }
    }

    private func historyNext() {
        guard !terminalHistory.isEmpty else { return }
        terminalHistoryIndex = min(terminalHistory.count, terminalHistoryIndex + 1)
        if terminalHistoryIndex >= terminalHistory.count {
            terminalInputField.text = ""
        } else {
            terminalInputField.text = terminalHistory[terminalHistoryIndex]
        }
    }

    /// Writes the boot banner — Mac-Terminal-style minimal first line,
    /// so the terminal doesn't look frozen while Python boots in the
    /// background. The REPL will overwrite this area with its own
    /// prompt once it's live.
    private func setTerminalInitialBanner() {
        terminalLogBuffer = ""
        terminalANSIState = ANSI.State()
        // ESC c (RIS, full terminal reset) — wipes the visible buffer,
        // resets attributes, scroll region, character set, etc.
        // ESC[3J — clear scrollback (RIS doesn't always purge it on
        // SwiftTerm's xterm emulator).
        // ESC[H — move cursor home so the banner starts in the
        // top-left, not wherever the previous prompt left it.
        //
        // Without these escapes, `terminalClearButton` and
        // `clearTerminal()` only reset our in-memory mirror — the user
        // still sees the old output on screen and the trash icon
        // looked broken. Sending the wipe sequences is what actually
        // empties SwiftTerm.
        swiftTermView.feed(text: "\u{1b}c\u{1b}[3J\u{1b}[H")
        // Render the same PS1 Python's offlinai_shell.Shell.prompt()
        // would emit — instant, so the user doesn't stare at "starting
        // python…" for the 1–2 s Py_Initialize + offlinai_shell import
        // takes on cold launch. Format / colors match the real prompt
        // exactly; offlinai_shell's repl() reads OFFLINAI_SHELL_NO_INTRO
        // and skips its banner + first-prompt emit so we don't double
        // up. Bytes typed into PTY before Python is reading get queued
        // by the kernel and flow through naturally once repl() opens
        // sys.stdin.
        let user = ProcessInfo.processInfo.environment["USER"]
            ?? ProcessInfo.processInfo.environment["LOGNAME"]
            ?? "mobile"
        let host = "localhost"   // Python side falls back to platform.machine
                                  // → "iPad" / "iPhone"; "localhost" matches
                                  // the most common iOS sandbox return.
        let promptLine =
            "\u{1b}[1m\(user)@\(host)\u{1b}[0m" +   // bold user@host
            " ~/Documents/Workspace " +
            "\u{1b}[1m%\u{1b}[0m "                  // bold trailing %
        swiftTermView.feed(text: promptLine)
        setenv("OFFLINAI_SHELL_NO_INTRO", "1", 1)
    }

    private func setTerminalStatus(_ s: TerminalStatus) {
        terminalStatusDot.backgroundColor = s.color
        terminalStatusLabel.text = s.title
        terminalStatusLabel.textColor = s.color
        if s == .running { terminalSpinner.startAnimating() } else { terminalSpinner.stopAnimating() }
        // Mirror onto the editor status bar so the user can see run
        // state without looking at the terminal pane (especially
        // useful when the terminal is minimized).
        updateEditorStatusState(s)
    }

    // MARK: - Setup Settings Panel

    private func setupSettingsPanel() {
        // Settings are shown as a popover — nothing to set up here
        // Controls are created fresh each time the popover opens
    }

    @objc private func manimQualityChanged(_ sender: UISegmentedControl) {
        UserDefaults.standard.set(sender.selectedSegmentIndex, forKey: "manim_quality")
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }

    @objc private func manimFPSChanged(_ sender: UISegmentedControl) {
        // Segment items are ["15", "24", "30"]; store the actual fps
        // value so PythonRuntime (which reads this as a raw integer)
        // gets a sensible value. Previously stored the raw index
        // (0/1/2) which Python then treated as fps=0/1/2 — every
        // render came out at one frame per second.
        let mapping = [15, 24, 30]
        let idx = sender.selectedSegmentIndex
        let fps = idx >= 0 && idx < mapping.count ? mapping[idx] : 24
        UserDefaults.standard.set(fps, forKey: "manim_fps")
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }

    // MARK: - Layout

    private func setupLayout() {
        // ManimStudio-style layout:
        //   Left panel = code editor + AI chat overlay (inline, right side of editor)
        //   Right = output/preview panel
        //   Bottom = terminal (full width)

        // Left panel layout (left → right):
        //   [files panel 220pt] [editorContainer fills] [aiChatContainer 0pt by default]
        // The files panel was previously mounted in the app's main
        // sidebar. We moved it into the editor here so it travels with
        // the editor pane (and the slim 64pt app sidebar stays slim).
        leftPanel.translatesAutoresizingMaskIntoConstraints = false
        leftPanel.addSubview(editorFilesPanel)
        leftPanel.addSubview(editorContainer)
        leftPanel.addSubview(aiChatContainer)

        // Files panel chrome — same `chrome bg` + 1pt indigo trailing
        // splitter as the app sidebar, so it reads as a peer surface.
        editorFilesPanel.translatesAutoresizingMaskIntoConstraints = false
        editorFilesPanel.backgroundColor = UIColor(red: 0x12/255.0, green: 0x12/255.0, blue: 0x1a/255.0, alpha: 1.0)
        editorFilesPanel.clipsToBounds = true
        let filesPanelSplitter = UIView()
        filesPanelSplitter.translatesAutoresizingMaskIntoConstraints = false
        filesPanelSplitter.backgroundColor = UIColor(red: 0x63/255.0, green: 0x66/255.0, blue: 0xf1/255.0, alpha: 0.15)
        editorFilesPanel.addSubview(filesPanelSplitter)

        // Embed the FilesBrowserViewController as a child of self,
        // pinned inside editorFilesPanel. Same delegate (self) so the
        // existing didSelectCodeFile / didRequestLoadModel routing
        // continues to drive loadFile() / model presentation.
        let fb = FilesBrowserViewController()
        fb.delegate = self
        addChild(fb)
        fb.view.translatesAutoresizingMaskIntoConstraints = false
        editorFilesPanel.addSubview(fb.view)
        fb.didMove(toParent: self)
        editorFilesBrowserController = fb

        // iPhone-friendly default: files panel collapsed at launch on
        // compact width since 220pt eats most of a 390pt iPhone screen.
        // User can still toggle it open via the toolbar's sidebar icon.
        let startCollapsed = isCompactWidth
        editorFilesPanelVisible = !startCollapsed
        editorFilesWidthConstraint = editorFilesPanel.widthAnchor.constraint(
            equalToConstant: startCollapsed ? 0 : 220)
        editorFilesWidthConstraint.isActive = true
        if startCollapsed { editorFilesPanel.alpha = 0 }

        // AI chat width: ~240pt fixed, overlays the right side of the editor
        // Start collapsed to match `isAIChatVisible = false` — user opens it
        // explicitly via the AI Assist toggle in the editor header.
        aiChatWidthConstraint = aiChatContainer.widthAnchor.constraint(equalToConstant: 0)
        aiChatContainer.alpha = 0

        NSLayoutConstraint.activate([
            // Files panel — leading edge of the left panel.
            editorFilesPanel.topAnchor.constraint(equalTo: leftPanel.topAnchor),
            editorFilesPanel.leadingAnchor.constraint(equalTo: leftPanel.leadingAnchor),
            editorFilesPanel.bottomAnchor.constraint(equalTo: leftPanel.bottomAnchor),

            filesPanelSplitter.topAnchor.constraint(equalTo: editorFilesPanel.topAnchor),
            filesPanelSplitter.trailingAnchor.constraint(equalTo: editorFilesPanel.trailingAnchor),
            filesPanelSplitter.bottomAnchor.constraint(equalTo: editorFilesPanel.bottomAnchor),
            filesPanelSplitter.widthAnchor.constraint(equalToConstant: 1),

            fb.view.topAnchor.constraint(equalTo: editorFilesPanel.topAnchor),
            fb.view.leadingAnchor.constraint(equalTo: editorFilesPanel.leadingAnchor),
            fb.view.trailingAnchor.constraint(equalTo: filesPanelSplitter.leadingAnchor),
            fb.view.bottomAnchor.constraint(equalTo: editorFilesPanel.bottomAnchor),

            // Editor — starts where files panel ends.
            editorContainer.topAnchor.constraint(equalTo: leftPanel.topAnchor),
            editorContainer.leadingAnchor.constraint(equalTo: editorFilesPanel.trailingAnchor),
            // Editor's right edge butts against the chat panel's left edge, so
            // the AI Assist button (which sits at the trailing end of the
            // editor header) stays visible & tappable when chat is open.
            editorContainer.trailingAnchor.constraint(equalTo: aiChatContainer.leadingAnchor),
            editorContainer.bottomAnchor.constraint(equalTo: leftPanel.bottomAnchor),

            // AI chat: right-aligned overlay inside the editor area
            aiChatContainer.topAnchor.constraint(equalTo: leftPanel.topAnchor),
            aiChatContainer.trailingAnchor.constraint(equalTo: leftPanel.trailingAnchor),
            aiChatContainer.bottomAnchor.constraint(equalTo: leftPanel.bottomAnchor),
            aiChatWidthConstraint,
        ])

        // 2-column: editor (with chat overlay) | output/preview.
        // spacing=0 so the panels share an edge — the outputPanel's
        // own 1pt leading border serves as the visible splitter
        // (single line, not a hair + a gap).
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topStack.axis = .horizontal
        topStack.spacing = 0
        topStack.distribution = .fill
        topStack.addArrangedSubview(leftPanel)
        topStack.addArrangedSubview(outputPanel)

        // Design CSS .ed-middle: `grid-template-columns: 1fr 521px` —
        // the output column starts at 521pt but the user can now drag
        // the editor↔output divider to widen/narrow the preview pane.
        // The chosen width is persisted in UserDefaults so it survives
        // relaunches. On iPhone (any orientation) we ZERO this so the
        // editor takes the full width; the user reaches the output
        // preview via the fullscreen-expand affordance instead. On
        // iPad we keep 521pt but cap at 50% of total so split-view
        // stays sane.
        let compactOutput = isCompactWidth
        let persisted = CGFloat(
            UserDefaults.standard.double(forKey: Self.kOutputPanelWidthKey))
        let initialWidth: CGFloat = {
            if compactOutput { return 0 }
            // 240pt is the smallest width that still shows a useful
            // preview; below that the chart is more annoying than
            // helpful. Cap at 900pt because anything larger means the
            // editor pane is too small to type in.
            if persisted >= 240, persisted <= 900 { return persisted }
            return 521
        }()
        outputPanelWidthConstraint = outputPanel.widthAnchor.constraint(
            equalToConstant: initialWidth)
        outputPanelWidthConstraint.priority = .init(900)
        outputPanelWidthConstraint.isActive = true
        if compactOutput { outputPanel.isHidden = true }
        let outputMaxFraction = outputPanel.widthAnchor.constraint(
            lessThanOrEqualTo: topStack.widthAnchor, multiplier: 0.5)
        outputMaxFraction.priority = .required
        outputMaxFraction.isActive = true

        // Main vertical stack: toolbar + topStack + terminal
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.axis = .vertical
        mainStack.spacing = 2
        mainStack.addArrangedSubview(toolbar)
        mainStack.addArrangedSubview(topStack)
        mainStack.addArrangedSubview(terminalContainer)

        view.addSubview(mainStack)

        // Resize handle: invisible 10pt-wide strip overlapping the
        // editor↔output edge. Must be installed AFTER the main stack
        // is in the view hierarchy — its constraints reference
        // ``outputPanel`` anchors, and the auto-layout engine refuses
        // to activate cross-tree constraints (the panel is reachable
        // via mainStack → topStack only once mainStack is a subview
        // of ``view``).
        if !compactOutput {
            outputDragHandle.translatesAutoresizingMaskIntoConstraints = false
            outputDragHandle.backgroundColor = .clear
            view.addSubview(outputDragHandle)
            NSLayoutConstraint.activate([
                outputDragHandle.widthAnchor.constraint(equalToConstant: 10),
                outputDragHandle.topAnchor.constraint(equalTo: outputPanel.topAnchor),
                outputDragHandle.bottomAnchor.constraint(equalTo: outputPanel.bottomAnchor),
                outputDragHandle.centerXAnchor.constraint(equalTo: outputPanel.leadingAnchor),
            ])
            let drag = UIPanGestureRecognizer(
                target: self, action: #selector(handleOutputResize(_:)))
            outputDragHandle.addGestureRecognizer(drag)
            // iPad cursor: change to horizontal-resize chevron when
            // hovering over the handle.
            if #available(iOS 13.4, *) {
                outputDragHandle.addInteraction(UIPointerInteraction(delegate: self))
            }
        }

        // Taller default: title bar (32) + textview + input bar (36). 200 gives
        // ~132 pt of visible scrollback on iPhone which is comfortable.
        terminalHeightConstraint = terminalContainer.heightAnchor.constraint(equalToConstant: 200)
        terminalHeightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: view.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            toolbar.heightAnchor.constraint(equalToConstant: 42),
            terminalHeightConstraint,
        ])
    }

    // MARK: - Default Code

    /// Clear the editor buffer. Used when no file is loaded — empty
    /// buffer lets the user start writing from a blank slate rather
    /// than fighting a hardcoded template.
    private func loadEmptyBuffer() {
        codeTextView.text = ""
        monacoView.setCode("", language: currentLanguage.monacoName)
    }

    /// File-browser → editor signal: a file/folder was just permanently
    /// deleted on disk. If it's our currently-open file, drop all
    /// references so the next auto-save tick doesn't resurrect it.
    /// Also catch the case where the deleted item is a parent folder
    /// of our open file — in that case our file is gone too.
    @objc private func handleFileDidDelete(_ note: Notification) {
        guard let deleted = note.object as? URL,
              let open = currentFileURL else { return }
        let openPath = open.standardizedFileURL.path
        let delPath = deleted.standardizedFileURL.path
        let affected = (openPath == delPath)
            || openPath.hasPrefix(delPath + "/")
        guard affected else { return }
        // Cancel the pending save and clear in-memory state for this
        // file. The editor buffer is left intact (user might want to
        // copy / paste into a new file) but currentFileURL goes nil
        // so any save tries to no-op rather than re-write the deleted
        // path. Also clear the persisted "last open" so a relaunch
        // doesn't try to re-open the now-missing file.
        autoSaveTimer?.cancel()
        autoSaveTimer = nil
        pendingSaveText = nil
        lastSavedText = nil
        currentFileURL = nil
        editorFileNameLabel.text = "(untitled)"
        applyLanguageTabStyle()
        modifiedDot.isHidden = true
        updateBreadcrumb()
        UserDefaults.standard.removeObject(forKey: "editor.lastFilePath")
        publishCurrentEditorFile(nil)
        appendToTerminal("$ \(deleted.lastPathComponent) deleted — editor buffer kept, save target cleared.\n",
                         isError: false)
    }

    /// SceneDelegate → editor signal: user picked CodeBench from the
    /// Files-app "Open With…" sheet, dropped a file on our icon, or
    /// shared one from another app. SceneDelegate has already copied
    /// the file into Documents/Imported/ (so we own a stable, non-
    /// security-scoped URL we can edit + auto-save freely).
    @objc private func handleOpenExternalFile(_ note: Notification) {
        guard let url = note.object as? URL else { return }
        // Flush any pending edits to the currently-open file before
        // swapping — so the user doesn't lose unsaved changes when
        // they tap "Open With…" mid-edit.
        if currentFileURL != nil {
            flushAutoSave()
        }
        loadFile(url: url)
        appendToTerminal("$ Imported \(url.lastPathComponent)\n", isError: false)
    }

    /// Restore the editor to whichever file was open when the app last
    /// quit, falling back to `~/Documents/Workspace/main.py`. The
    /// fallback file is created EMPTY — no language template is
    /// injected. (Earlier versions seeded `main.py` with a Python
    /// "Hello World" template, but that was clutter for users who
    /// already know what they want to write.)
    private func loadInitialFile() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let workspace = docs?.appendingPathComponent("Workspace") else {
            loadEmptyBuffer(); return
        }
        try? fm.createDirectory(at: workspace, withIntermediateDirectories: true)

        // Last-opened file (persisted in UserDefaults across app launches).
        if let lastPath = UserDefaults.standard.string(forKey: "editor.lastFilePath"),
           fm.fileExists(atPath: lastPath) {
            loadFile(url: URL(fileURLWithPath: lastPath))
            return
        }

        // Fallback: ~/Documents/Workspace/main.py — created empty.
        let main = workspace.appendingPathComponent("main.py")
        if !fm.fileExists(atPath: main.path) {
            try? "".write(to: main, atomically: true, encoding: .utf8)
        }
        loadFile(url: main)
    }

    // MARK: - Actions

    @objc private func languageChanged() {
        currentLanguage = Language(rawValue: languageControl.selectedSegmentIndex) ?? .python
        // Just retag Monaco's syntax highlighting — DON'T overwrite
        // the buffer with a template. The user's existing code stays
        // put; if they switched languages and the old code happens to
        // be invalid for the new one, that's their call.
        monacoView.setLanguage(currentLanguage.monacoName)
        applyLanguageTabStyle()
    }

    @objc private func runTapped() {
        // Fetch the latest text from Monaco (async) before running
        monacoView.getText { [weak self] code in
            guard let self else { return }
            self.codeTextView.text = code  // update mirror
            // Flush to disk before running — users expect that "run"
            // saves, matching every other code editor.
            if let url = self.currentFileURL {
                try? code.write(to: url, atomically: true, encoding: .utf8)
                self.lastSavedText = code
                self.pendingSaveText = nil
            }
            self._runWithCode(code)
        }
    }

    /// Regex-scan Python source for `class X(<base>):` definitions whose
    /// base class chain mentions `Scene`. Returns the class names in
    /// definition order. Catches stock manim `Scene`, `MovingCameraScene`,
    /// `ThreeDScene`, `LinearTransformationScene`, `ZoomedScene`,
    /// `VectorScene`, `GraphScene`, `SpecialThreeDScene`, and any user
    /// subclass like `MyBaseScene` because we just check whether `Scene`
    /// appears anywhere in the parens.
    ///
    /// This is heuristic-only — Python's actual class detection happens
    /// in the wrapper after exec, but we need the names BEFORE the run
    /// to populate the picker. False positives (a base class with
    /// "Scene" in the name that isn't a manim Scene) just mean the
    /// picker offers an option that the wrapper then can't find — which
    /// falls back to "render all" so it's not fatal.
    static func detectSceneClasses(in code: String) -> [String] {
        // class <Name>(<bases-with-Scene-anywhere>):
        // - Multiline-comment / string-aware: not really, but `class ` at
        //   line start outside a multiline string is the overwhelming case.
        // - We deduplicate while preserving order in case the user has
        //   the same name twice (last definition wins in Python anyway).
        let pattern = #"(?m)^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*:"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(code.startIndex..<code.endIndex, in: code)
        let matches = re.matches(in: code, options: [], range: nsRange)
        var seen = Set<String>()
        var result: [String] = []
        for m in matches where m.numberOfRanges == 3 {
            guard let nameRange = Range(m.range(at: 1), in: code),
                  let basesRange = Range(m.range(at: 2), in: code) else { continue }
            let name = String(code[nameRange])
            let bases = String(code[basesRange])
            // Underscored names are convention-private — manim's auto-
            // render skips them, mirror that here so they don't clutter
            // the picker.
            guard !name.hasPrefix("_") else { continue }
            guard bases.contains("Scene") else { continue }
            if seen.insert(name).inserted {
                result.append(name)
            }
        }
        return result
    }

    /// Show a picker action sheet for the detected Scene subclasses.
    /// `completion(nil)` is called if the user cancels (run is aborted),
    /// `completion("*")` for "render all" (legacy behaviour), or the
    /// bare class name for a single-scene render.
    private func presentScenePicker(scenes: [String], completion: @escaping (String?) -> Void) {
        let alert = UIAlertController(
            title: "Pick a Scene",
            message: "This script defines \(scenes.count) Scene subclasses. Pick one to render — or render them all.",
            preferredStyle: .actionSheet)

        for name in scenes {
            alert.addAction(UIAlertAction(title: name, style: .default) { _ in
                completion(name)
            })
        }
        alert.addAction(UIAlertAction(title: "Render all (\(scenes.count))", style: .default) { _ in
            completion("*")
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completion(nil)
        })

        // iPad popovers must be anchored. Anchor on the run button, with
        // a sensible fallback to the toolbar's frame if the button isn't
        // in the hierarchy yet (shouldn't happen, but defensive).
        if let popover = alert.popoverPresentationController {
            popover.sourceView = runButton
            popover.sourceRect = runButton.bounds
            popover.permittedArrowDirections = [.any]
        }

        present(alert, animated: true)
    }

    private func _runWithCode(_ code: String) {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendToTerminal("$ No code to run.\n", isError: true)
            return
        }

        // Manim-only: if the script defines more than one Scene
        // subclass, ask which one to render BEFORE we burn 10 minutes
        // auto-rendering all of them. Single-Scene scripts skip the
        // dialog and run straight through.
        if currentLanguage == .python {
            let scenes = Self.detectSceneClasses(in: code)
            if scenes.count >= 2 {
                presentScenePicker(scenes: scenes) { [weak self] choice in
                    guard let self else { return }
                    guard let choice else {
                        // User cancelled the picker — abort rather than
                        // running with an unintended default.
                        self.appendToTerminal("$ Run cancelled.\n", isError: false)
                        return
                    }
                    self._runWithCodeAndScene(code, scene: choice)
                }
                return
            }
        }

        _runWithCodeAndScene(code, scene: nil)
    }

    private func _runWithCodeAndScene(_ code: String, scene: String?) {
        // Reset ANSI state so a color leaked by a previous crash can't
        // recolor the next run's output.
        terminalANSIState = ANSI.State()

        runButton.isEnabled = false
        setTerminalStatus(.running)
        if let scene, scene != "*" {
            appendToTerminal("$ Running \(currentLanguage.title) (scene: \(scene))…\n", isError: false)
        } else {
            appendToTerminal("$ Running \(currentLanguage.title)…\n", isError: false)
        }

        // Background-execution guard. DEFAULT: ON. The user can opt out
        // by setting UserDefaults "background_execution_enabled" = false
        // (e.g. from a future Settings toggle). Using object-lookup
        // rather than bool() so an absent key means "use the default",
        // not "false".
        let bgEnabled = (UserDefaults.standard.object(
            forKey: "background_execution_enabled") as? Bool) ?? true
        if bgEnabled {
            // Pass the file name + selected scene so the Live Activity
            // and lock-screen fallback notification show what's actually
            // running, not a generic "CodeBench" string.
            let activityTitle = currentFileURL?.lastPathComponent ?? "Untitled"
            let activitySubtitle: String
            if let scene, scene != "*" {
                activitySubtitle = "Rendering \(scene)…"
            } else {
                activitySubtitle = "Running \(currentLanguage.title)…"
            }
            BackgroundExecutionGuard.shared.start(
                title: activityTitle, subtitle: activitySubtitle)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let start = CFAbsoluteTimeGetCurrent()
            var output = ""
            var hasError = false
            var resultImagePath: String?
            var didStream = false

            switch self.currentLanguage {
            case .python:
                didStream = true
                let result = PythonRuntime.shared.execute(code: code, targetScene: scene) { [weak self] chunk in
                    DispatchQueue.main.async {
                        // Filter out internal-debug prefixes ([diag],
                        // [fallback], [py-exec], [manim-font], [manim
                        // rendered]) — they're routed to NSLog instead
                        // so the in-app terminal stays focused on what
                        // the user's script actually prints.
                        self?.appendToTerminalFiltered(chunk, isError: false)
                    }
                }
                output = result.output.isEmpty ? "" : result.output
                hasError = output.lowercased().contains("error") || output.contains("Traceback")
                resultImagePath = result.imagePath

            case .c:
                let result = CRuntime.shared.execute(code)
                if result.success {
                    output = result.output.isEmpty ? "(no output)" : result.output
                } else {
                    output = "Error: \(result.error ?? "unknown")\n\(result.output)"
                    hasError = true
                }

            case .cpp:
                let result = CppRuntime.shared.execute(code)
                if result.success {
                    output = result.output.isEmpty ? "(no output)" : result.output
                } else {
                    output = "Error: \(result.error ?? "unknown")\n\(result.output)"
                    hasError = true
                }

            case .fortran:
                let result = FortranRuntime.shared.execute(code)
                if result.success {
                    output = result.output.isEmpty ? "(no output)" : result.output
                } else {
                    output = "Error: \(result.error ?? "unknown")\n\(result.output)"
                    hasError = true
                }

            case .swift:
                // Pure-Swift tree-walking interpreter (App Store safe — no JIT).
                // Covers tier-2 Swift: literals, control flow, functions,
                // closures, optionals, arrays/dicts/tuples, ranges.
                // See SwiftInterpreter.swift for full feature matrix.
                let result = SwiftRuntime.shared.execute(code)
                if result.success {
                    output = result.output.isEmpty ? "(no output)" : result.output
                } else {
                    output = "Error: \(result.error ?? "unknown")\n\(result.output)"
                    hasError = true
                }

            case .latex:
                // Drive the existing offlinai_latex.compile_doc() flow:
                // write the editor's text to a .tex file, ask the
                // LaTeX engine to compile it via Python, and show the
                // resulting PDF in the output panel. This is the same
                // path the terminal's `pdflatex foo.tex` builtin uses,
                // so CJK auto-routing to xelatex etc. all work.
                let result = self.compileLaTeXSync(source: code)
                if let pdfPath = result.pdfPath {
                    output = "PDF written: \(pdfPath)\n\(result.log)"
                    resultImagePath = pdfPath  // showImageOutput accepts PDF
                } else {
                    output = "LaTeX failed (status=\(result.status))\n\(result.log)"
                    hasError = true
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start

            DispatchQueue.main.async {
                // Pair with the start() above (only call stop() if we
                // actually called start() — otherwise the depth counter
                // would underflow).
                if bgEnabled {
                    BackgroundExecutionGuard.shared.stop()
                }

                self.runButton.isEnabled = true
                // Mark this chart as the freshly-shown one so the
                // dir-watch fallback doesn't immediately re-fire on
                // the same file we just loaded via the Run button.
                if let p = resultImagePath {
                    self.lastShownChartPath = p
                    self.lastShownChartTime = Date()
                    self.showImageOutput(path: p)
                }
                // If the script produced NO chart path itself, leave the
                // preview pane alone — it may already be showing content
                // from a mid-script signal (pywebview's preview_request,
                // a load_html(), a load_url()). Earlier behaviour called
                // showImageOutput(nil) unconditionally, which hid the
                // pywebview WKWebView and wiped its DOM with a blank
                // HTML string — so `webview.create_window(...)` worked
                // for ~100 ms then vanished the instant the script
                // returned.

                if didStream {
                    // Output was already streamed to terminal — only show errors & timing
                    if hasError && !output.isEmpty {
                        // Show stderr that wasn't streamed
                        let stderrOnly = output.components(separatedBy: "stderr:\n").dropFirst().joined(separator: "\n")
                        if !stderrOnly.isEmpty {
                            self.appendToTerminal(stderrOnly + "\n", isError: true)
                        }
                    }
                    // Diag/fallback notes used to print into the in-app
                    // terminal — they're noisy and only useful while
                    // debugging path-discovery, so they now go to NSLog
                    // (visible in Xcode console / Console.app) instead.
                    let lines = output.components(separatedBy: "\n").filter {
                        $0.hasPrefix("[diag]") || $0.hasPrefix("[fallback]")
                    }
                    for line in lines {
                        NSLog("[py] %@", line)
                    }
                } else {
                    self.appendToTerminal("> \(output)\n", isError: hasError)
                }

                let status = hasError ? "completed with errors" : "completed"
                self.appendToTerminal("$ Execution \(status) in \(String(format: "%.3f", elapsed))s\n", isError: false)
                self.setTerminalStatus(hasError ? .failure : .success)
            }
        }
    }

    @objc private func clearTerminal() {
        setTerminalInitialBanner()
        setTerminalStatus(.ready)

        // Clear output panel
        outputImageView.isHidden = true
        outputImageView.image = nil
        outputWebView.isHidden = true
        setOutputEmptyStateHidden(false)

        terminalHeightConstraint.constant = 200
        view.layoutIfNeeded()
    }

    /// "Open" toolbar button — present the system document picker so the
    /// user can browse the Files app for any source file (including
    /// iCloud Drive, OneDrive, Dropbox, On My iPad…) and load it into
    /// the editor. Accepts every UTI we declared in Info.plist's
    /// CFBundleDocumentTypes / UTImportedTypeDeclarations plus the
    /// generic .text / .sourceCode / .data fallbacks so files without a
    /// registered UTI (.toml, .lock, .gitignore, custom configs) still
    /// open. The picker copies the file into the app sandbox by default;
    /// loadFile() then reads it via the same path used for taps in the
    /// in-app file browser, so syntax highlighting / autocomplete / the
    /// editor's recent-file list all light up automatically.
    @objc private func openFileTapped() {
        let types: [UTType] = [
            .pythonScript, .sourceCode, .swiftSource, .cSource, .cPlusPlusSource,
            .objectiveCSource, .objectiveCPlusPlusSource, .cHeader, .cPlusPlusHeader,
            .shellScript, .json, .xml, .html, .javaScript, .plainText,
            .utf8PlainText, .utf16PlainText, .text, .data,
        ]
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .formSheet
        present(picker, animated: true)
    }

    /// Public hook for the Workspace Dashboard: ensure the AI Assist
    /// panel is visible. No-op if it's already up. Used by the
    /// `AI Chat` dashboard card so tapping it directly opens the
    /// chat instead of just switching tabs.
    func showAIChatPanel() {
        if !isAIChatVisible { toggleAIChat() }
    }

    /// Public hook for the Workspace Dashboard: trigger the same
    /// action as tapping the green Run button in the editor toolbar.
    func runCurrentFile() {
        runTapped()
    }

    @objc private func toggleAIChat() {
        isAIChatVisible.toggle()
        // Slide the inline chat panel in from / out to the right edge.
        aiChatWidthConstraint.constant = isAIChatVisible ? 260 : 0
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) {
            self.aiChatContainer.alpha = self.isAIChatVisible ? 1.0 : 0.0
            self.view.layoutIfNeeded()
        }
        applyAIToggleStyle()
        // Light haptic feedback so the toggle feels tactile.
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.impactOccurred()
    }

    /// Repaints the AI Assist pill to reflect `isAIChatVisible`.
    /// OFF: outline pill, muted violet icon, "AI Assist" label.
    /// ON : filled violet pill, white icon + checkmark hint, stronger border.
    private func applyAIToggleStyle() {
        let iconName = isAIChatVisible ? "sparkles.rectangle.stack.fill" : "sparkles"
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(
            systemName: iconName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        )
        cfg.imagePadding = 5
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        var attr = AttributeContainer()
        attr.font = .systemFont(ofSize: 11, weight: .semibold)
        let title = isAIChatVisible ? "AI Assist · ON" : "AI Assist"
        cfg.attributedTitle = AttributedString(title, attributes: attr)
        cfg.baseForegroundColor = isAIChatVisible ? .white : EditorTheme.accentViolet
        aiToggleButton.configuration = cfg
        aiToggleButton.backgroundColor = isAIChatVisible
            ? EditorTheme.accent.withAlphaComponent(0.85)
            : EditorTheme.accent.withAlphaComponent(0.10)
        aiToggleButton.layer.borderColor = (isAIChatVisible
            ? EditorTheme.accentViolet
            : EditorTheme.accent.withAlphaComponent(0.35)).cgColor
    }

    @objc private func showLaTeXPreview() {
        let previewVC = LaTeXPreviewViewController()
        previewVC.modalPresentationStyle = .popover
        previewVC.preferredContentSize = CGSize(width: 500, height: 520)
        if let pop = previewVC.popoverPresentationController {
            pop.sourceView = latexTestButton
            pop.sourceRect = latexTestButton.bounds
            pop.permittedArrowDirections = .up
            pop.delegate = self
        }
        present(previewVC, animated: true)
    }

    @objc private func toggleSettingsPanel() {
        let popoverVC = UIViewController()
        popoverVC.modalPresentationStyle = .popover
        popoverVC.preferredContentSize = CGSize(width: 280, height: 220)

        let popView = popoverVC.view!
        popView.backgroundColor = EditorTheme.chatBg

        let titleLabel = UILabel()
        titleLabel.text = "Manim Settings"
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = EditorTheme.foreground
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let qualityLabel = UILabel()
        qualityLabel.text = "Quality"
        qualityLabel.font = .systemFont(ofSize: 12, weight: .medium)
        qualityLabel.textColor = EditorTheme.gutterText
        qualityLabel.translatesAutoresizingMaskIntoConstraints = false

        // Create fresh segmented controls for the popover (don't re-parent instance properties)
        let qualitySeg = UISegmentedControl(items: ["Low 480p", "Med 720p", "High 1080p"])
        qualitySeg.selectedSegmentIndex = UserDefaults.standard.integer(forKey: "manim_quality")
        qualitySeg.translatesAutoresizingMaskIntoConstraints = false
        qualitySeg.backgroundColor = EditorTheme.gutterBg
        qualitySeg.selectedSegmentTintColor = UIColor.systemPurple.withAlphaComponent(0.5)
        qualitySeg.setTitleTextAttributes([.foregroundColor: EditorTheme.foreground, .font: UIFont.systemFont(ofSize: 11)], for: .normal)
        qualitySeg.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 11, weight: .semibold)], for: .selected)
        qualitySeg.addTarget(self, action: #selector(manimQualityChanged(_:)), for: .valueChanged)

        let fpsLabel = UILabel()
        fpsLabel.text = "Frame Rate"
        fpsLabel.font = .systemFont(ofSize: 12, weight: .medium)
        fpsLabel.textColor = EditorTheme.gutterText
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false

        let fpsSeg = UISegmentedControl(items: ["15", "24", "30"])
        // manim_fps now stores the ACTUAL fps value (15/24/30), not
        // the segment index. Map back so the right segment is
        // pre-selected.
        let storedFPS = UserDefaults.standard.integer(forKey: "manim_fps")
        fpsSeg.selectedSegmentIndex = [15, 24, 30].firstIndex(of: storedFPS) ?? 0
        fpsSeg.translatesAutoresizingMaskIntoConstraints = false
        fpsSeg.backgroundColor = EditorTheme.gutterBg
        fpsSeg.selectedSegmentTintColor = UIColor.systemPurple.withAlphaComponent(0.5)
        fpsSeg.setTitleTextAttributes([.foregroundColor: EditorTheme.foreground, .font: UIFont.systemFont(ofSize: 12)], for: .normal)
        fpsSeg.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 12, weight: .semibold)], for: .selected)
        fpsSeg.addTarget(self, action: #selector(manimFPSChanged(_:)), for: .valueChanged)

        popView.addSubview(titleLabel)
        popView.addSubview(qualityLabel)
        popView.addSubview(qualitySeg)
        popView.addSubview(fpsLabel)
        popView.addSubview(fpsSeg)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: popView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: popView.leadingAnchor, constant: 16),

            qualityLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            qualityLabel.leadingAnchor.constraint(equalTo: popView.leadingAnchor, constant: 16),

            qualitySeg.topAnchor.constraint(equalTo: qualityLabel.bottomAnchor, constant: 6),
            qualitySeg.leadingAnchor.constraint(equalTo: popView.leadingAnchor, constant: 16),
            qualitySeg.trailingAnchor.constraint(equalTo: popView.trailingAnchor, constant: -16),

            fpsLabel.topAnchor.constraint(equalTo: qualitySeg.bottomAnchor, constant: 16),
            fpsLabel.leadingAnchor.constraint(equalTo: popView.leadingAnchor, constant: 16),

            fpsSeg.topAnchor.constraint(equalTo: fpsLabel.bottomAnchor, constant: 6),
            fpsSeg.leadingAnchor.constraint(equalTo: popView.leadingAnchor, constant: 16),
            fpsSeg.trailingAnchor.constraint(equalTo: popView.trailingAnchor, constant: -16),
        ])

        if let popoverPresentation = popoverVC.popoverPresentationController {
            popoverPresentation.sourceView = settingsButton
            popoverPresentation.sourceRect = settingsButton.bounds
            popoverPresentation.permittedArrowDirections = .up
            popoverPresentation.backgroundColor = EditorTheme.chatBg
            popoverPresentation.delegate = self
        }

        present(popoverVC, animated: true)
    }

    @objc private func sendChatMessage() {
        guard let text = chatInputField.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        chatInputField.text = ""
        chatInputField.resignFirstResponder()

        addChatBubble(text: text, isUser: true)

        let code = codeTextView.text ?? ""
        let langName = currentLanguage.title.lowercased()
        let prompt = "Here is my \(langName) code:\n```\(langName)\n\(code)\n```\n\nUser question: \(text)"

        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are a helpful coding assistant integrated with a code editor. Answer concisely about the user's code. When suggesting code changes, ALWAYS include the complete updated code in a ```\(langName) code block so the user can apply it directly to the editor. Keep responses under 300 words."),
            ChatMessage(role: .user, content: prompt)
        ]

        guard let runner = llamaRunner else {
            addChatBubble(text: "No model loaded. Load a model from the Models tab in the sidebar first.", isUser: false)
            return
        }

        // State for streaming with think/answer splitting
        var rawBuffer = ""
        var thinkingText = ""
        var answerText = ""
        var isInThink = false
        var sawThink = false
        let startTime = Date()

        // Create the thinking pill (collapsible, like ChatGPT "Thought for Xs >")
        let thinkPill = self.makeThinkingPill()
        chatStackView.addArrangedSubview(thinkPill.container)

        // Create answer label (streams below the thinking pill)
        let answerLabel = addChatBubble(text: "", isUser: false)

        runner.generate(messages: messages, maxTokens: 2048, onToken: { [weak self] token in
            rawBuffer += token

            // Parse <think>...</think> tags
            DispatchQueue.main.async {
                guard let self else { return }

                // Detect think open
                if !sawThink {
                    let lower = rawBuffer.lowercased()
                    if lower.contains("<think>") || lower.contains("<thinking>") {
                        sawThink = true
                        isInThink = true
                        // Strip the tag from buffer
                        for tag in ["<think>", "<thinking>"] {
                            if let r = rawBuffer.range(of: tag, options: .caseInsensitive) {
                                thinkingText = String(rawBuffer[r.upperBound...])
                                rawBuffer = ""
                                break
                            }
                        }
                        thinkPill.label.text = "Thinking..."
                        thinkPill.container.isHidden = false
                        self.scrollChatToBottom()
                        return
                    }
                }

                // Inside thinking section
                if isInThink {
                    thinkingText += token
                    // Check for close tag
                    let lower = thinkingText.lowercased()
                    for tag in ["</think>", "</thinking>"] {
                        if let r = lower.range(of: tag) {
                            let cleanThink = String(thinkingText[thinkingText.startIndex..<thinkingText.index(thinkingText.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound))])
                            thinkingText = cleanThink
                            isInThink = false
                            // Update pill with elapsed time
                            let elapsed = Int(Date().timeIntervalSince(startTime))
                            thinkPill.label.text = "Thought for \(elapsed)s"
                            thinkPill.detail.text = thinkingText.trimmingCharacters(in: .whitespacesAndNewlines)
                            // Any text after close tag is answer
                            if let tagRange = rawBuffer.range(of: tag, options: .caseInsensitive) {
                                answerText = String(rawBuffer[tagRange.upperBound...])
                                answerLabel.text = answerText
                            }
                            rawBuffer = ""
                            break
                        }
                    }
                    // Live update thinking pill
                    if isInThink {
                        let elapsed = Int(Date().timeIntervalSince(startTime))
                        thinkPill.label.text = "Thinking... \(elapsed)s"
                    }
                    self.scrollChatToBottom()
                    return
                }

                // Normal answer text (after thinking or no thinking)
                if sawThink && !isInThink {
                    answerText += token
                } else if !sawThink {
                    answerText = rawBuffer
                }
                answerLabel.text = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
                self.scrollChatToBottom()
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let full):
                    // Strip think tags from final text for answer
                    var finalAnswer = full
                    // Remove <think>...</think> block
                    if let thinkPattern = try? NSRegularExpression(pattern: "<think(?:ing)?>([\\s\\S]*?)</think(?:ing)?>", options: .caseInsensitive) {
                        finalAnswer = thinkPattern.stringByReplacingMatches(in: finalAnswer, range: NSRange(finalAnswer.startIndex..., in: finalAnswer), withTemplate: "")
                    }
                    // Also strip <answer> tags
                    for tag in ["<answer>", "</answer>", "<|answer|>", "<|im_start|>answer"] {
                        finalAnswer = finalAnswer.replacingOccurrences(of: tag, with: "", options: .caseInsensitive)
                    }
                    finalAnswer = finalAnswer.trimmingCharacters(in: .whitespacesAndNewlines)

                    // Render with markdown
                    self.renderMarkdownText(finalAnswer, into: answerLabel)

                    // Finalize thinking pill
                    if sawThink {
                        let elapsed = Int(Date().timeIntervalSince(startTime))
                        thinkPill.label.text = "Thought for \(elapsed)s  ›"
                    } else {
                        thinkPill.container.isHidden = true
                    }

                    // Add Apply button if code block present
                    self.addApplyButtonIfCodeBlock(finalAnswer, below: answerLabel)
                case .failure(let error):
                    answerLabel.text = "❌ \(error.localizedDescription)"
                    answerLabel.textColor = EditorTheme.terminalError
                    if sawThink {
                        thinkPill.label.text = "Thought (error)"
                    } else {
                        thinkPill.container.isHidden = true
                    }
                }
                self.scrollChatToBottom()
            }
        })
    }

    // MARK: - Apply Code from AI Chat

    private func extractCodeBlock(_ text: String) -> String? {
        // Match ```language\n...\n``` or ```\n...\n```
        let pattern = "```(?:\\w+)?\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let codeRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[codeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Stable key for objc_setAssociatedObject
    private static var codeBlockKey: UInt8 = 0

    private func addApplyButtonIfCodeBlock(_ text: String, below label: UILabel) {
        guard let code = extractCodeBlock(text) else { return }

        var applyConfig = UIButton.Configuration.filled()
        applyConfig.title = "Apply to Editor"
        applyConfig.image = UIImage(systemName: "doc.on.clipboard")
        applyConfig.imagePadding = 6
        applyConfig.baseBackgroundColor = UIColor.systemBlue.withAlphaComponent(0.20)
        applyConfig.baseForegroundColor = .systemBlue
        applyConfig.cornerStyle = .medium
        applyConfig.buttonSize = .small
        applyConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)

        let applyButton = UIButton(type: .system)
        applyButton.configuration = applyConfig
        applyButton.translatesAutoresizingMaskIntoConstraints = false

        // Store code with a stable pointer key
        objc_setAssociatedObject(applyButton, &Self.codeBlockKey, code, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        applyButton.addTarget(self, action: #selector(applyCodeToEditor(_:)), for: .touchUpInside)

        chatStackView.addArrangedSubview(applyButton)
        NSLayoutConstraint.activate([
            applyButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @objc private func applyCodeToEditor(_ sender: UIButton) {
        guard let code = objc_getAssociatedObject(sender, &Self.codeBlockKey) as? String else { return }
        codeTextView.text = code  // mirror
        monacoView.setCode(code, language: currentLanguage.monacoName)

        // Visual feedback
        var cfg = UIButton.Configuration.filled()
        cfg.title = "Applied!"
        cfg.image = UIImage(systemName: "checkmark")
        cfg.imagePadding = 6
        cfg.baseBackgroundColor = UIColor.systemGreen.withAlphaComponent(0.20)
        cfg.baseForegroundColor = .systemGreen
        cfg.cornerStyle = .medium
        cfg.buttonSize = .small
        sender.configuration = cfg
        sender.isEnabled = false
    }

    // MARK: - Output Panel Resize
    //
    // Pan the editor↔output divider to widen / narrow the preview
    // pane. The width is clamped so neither side disappears entirely
    // and persisted in UserDefaults so the next launch starts at the
    // user's preferred size.

    @objc private func handleOutputResize(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            outputPanelDragStartWidth = outputPanelWidthConstraint.constant
        case .changed:
            let translation = gesture.translation(in: view)
            // Right edge of editor is the LEFT edge of output panel.
            // Drag handle moves left → output gets WIDER (negative tx),
            // drag right → output gets NARROWER (positive tx).
            let proposed = outputPanelDragStartWidth - translation.x
            let maxWidth = max(240, topStack.bounds.width - 320)  // keep ≥320pt for the editor
            let clamped = max(240, min(proposed, maxWidth))
            outputPanelWidthConstraint.constant = clamped
        case .ended, .cancelled:
            UserDefaults.standard.set(
                Double(outputPanelWidthConstraint.constant),
                forKey: Self.kOutputPanelWidthKey)
        default:
            break
        }
    }

    // MARK: - Terminal Resize

    @objc private func handleTerminalDrag(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        if gesture.state == .changed {
            let newHeight = terminalHeightConstraint.constant - translation.y
            terminalHeightConstraint.constant = max(60, min(newHeight, view.bounds.height * 0.6))
            gesture.setTranslation(.zero, in: view)
        }
    }

    // MARK: - Copy Terminal

    @objc private func copyTerminalContents() {
        // Strip ANSI escape sequences so pasted text is clean plain
        // text rather than `[38;5;244m...[0m` gibberish. Covers CSI
        // (ESC [ … m/K/H/J etc.), OSC (ESC ] … ST/BEL), and single-
        // char ESC-prefixed controls.
        let raw = terminalLogBuffer
        var cleaned = ""
        cleaned.reserveCapacity(raw.count)
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == "\u{1b}" {  // ESC
                let next = raw.index(after: i)
                if next >= raw.endIndex {
                    i = next
                    continue
                }
                let k = raw[next]
                if k == "[" {
                    // CSI: ESC [ … <final-byte> where final byte is in
                    // the range 0x40–0x7E (A–Z, a–z, @[\]^_`{|}~).
                    var j = raw.index(after: next)
                    while j < raw.endIndex {
                        let b = raw[j]
                        let scalar = b.unicodeScalars.first?.value ?? 0
                        if scalar >= 0x40 && scalar <= 0x7E {
                            break
                        }
                        j = raw.index(after: j)
                    }
                    i = j < raw.endIndex ? raw.index(after: j) : raw.endIndex
                } else if k == "]" {
                    // OSC: ESC ] … (BEL | ESC \)
                    var j = raw.index(after: next)
                    while j < raw.endIndex {
                        let b = raw[j]
                        if b == "\u{07}" { break }
                        if b == "\u{1b}",
                           raw.index(after: j) < raw.endIndex,
                           raw[raw.index(after: j)] == "\\" {
                            j = raw.index(after: j)
                            break
                        }
                        j = raw.index(after: j)
                    }
                    i = j < raw.endIndex ? raw.index(after: j) : raw.endIndex
                } else {
                    // Single-char control (ESC N, ESC M, ESC 7, etc.)
                    i = raw.index(after: next)
                }
            } else {
                cleaned.append(c)
                i = raw.index(after: i)
            }
        }
        UIPasteboard.general.string = cleaned

        // Brief tactile + visual feedback
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // Flash the button label to "Copied"
        var flashed = terminalCopyButton.configuration ?? UIButton.Configuration.plain()
        flashed.attributedTitle = AttributedString("Copied", attributes: AttributeContainer([
            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .medium),
        ]))
        flashed.image = UIImage(systemName: "checkmark",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        flashed.baseForegroundColor = UIColor.systemGreen
        terminalCopyButton.configuration = flashed

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            var restored = self.terminalCopyButton.configuration ?? UIButton.Configuration.plain()
            restored.image = UIImage(systemName: "doc.on.doc",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
            restored.baseForegroundColor = UIColor(white: 0.7, alpha: 1)
            self.terminalCopyButton.configuration = restored
        }
    }

    // MARK: - Terminal window controls (Mac-style)

    /// Red traffic light: collapse the terminal pane to 0 height. A
    /// translucent "show terminal" chip appears in the top-right of the
    /// editor so it can be restored. The terminal itself is NOT destroyed
    /// (state + scrollback + input history are preserved).
    @objc private func terminalClose() {
        // Save current height if the user hadn't just hit maximize.
        if terminalWindowState == .normal {
            terminalNormalHeight = terminalHeightConstraint.constant
        }
        // DON'T shrink the swiftTermView — that would reflow its
        // contents (rows change, scrollback snaps to the last line).
        // Instead, just hide the container. swiftTermView's internal
        // cols/rows/scrollback are preserved exactly as the user left
        // them, and restoring shows the same view unchanged.
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut]) {
            self.terminalContainer.alpha = 0
        } completion: { _ in
            self.terminalContainer.isHidden = true
        }
        showTerminalRestoreChip()
    }

    /// Yellow traffic light: toggle minimized state. Minimizing hides
    /// the swiftTermView (not resizing) so reflow never happens — the
    /// terminal content is preserved byte-for-byte on restore.
    @objc private func terminalMinimize() {
        if terminalWindowState == .minimized {
            // Already minimized — restore to normal.
            terminalWindowState = .normal
            swiftTermView.isHidden = false
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut]) {
                self.swiftTermView.alpha = 1
                self.terminalHeightConstraint.constant = max(self.terminalNormalHeight, 180)
                self.view.layoutIfNeeded()
            }
        } else {
            if terminalWindowState == .normal {
                terminalNormalHeight = terminalHeightConstraint.constant
            }
            terminalWindowState = .minimized
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut]) {
                self.swiftTermView.alpha = 0
                self.terminalHeightConstraint.constant = 36
                self.view.layoutIfNeeded()
            } completion: { _ in
                self.swiftTermView.isHidden = true
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Green traffic light: expand to ~70% of the editor height, or
    /// toggle back to the previous height.
    ///
    /// Maximize DOES intentionally reflow — that's the whole point of
    /// the button: show more rows. If the user wants no-reflow expand,
    /// they can drag the top edge instead.
    @objc private func terminalMaximize() {
        // Coming back from hidden/minimized? Un-hide swiftTermView first.
        if swiftTermView.isHidden || swiftTermView.alpha < 1 {
            swiftTermView.isHidden = false
            UIView.animate(withDuration: 0.15) {
                self.swiftTermView.alpha = 1
            }
        }
        if terminalWindowState == .maximized {
            terminalWindowState = .normal
            UIView.animate(withDuration: 0.22) {
                self.terminalHeightConstraint.constant = self.terminalNormalHeight
                self.view.layoutIfNeeded()
            }
        } else {
            if terminalWindowState == .normal {
                terminalNormalHeight = terminalHeightConstraint.constant
            }
            terminalWindowState = .maximized
            let maxH = view.bounds.height * 0.70
            UIView.animate(withDuration: 0.22) {
                self.terminalHeightConstraint.constant = maxH
                self.view.layoutIfNeeded()
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// A small "▸ Terminal" chip that appears in the toolbar area when the
    /// terminal is fully closed so the user has a way back. Tapping it
    /// restores the terminal to its last remembered height.
    private var terminalRestoreChip: UIButton?
    private func showTerminalRestoreChip() {
        if let chip = terminalRestoreChip { chip.isHidden = false; return }
        let chip = UIButton(type: .system)
        chip.translatesAutoresizingMaskIntoConstraints = false
        var cfg = UIButton.Configuration.filled()
        cfg.title = "Show terminal"
        cfg.image = UIImage(systemName: "chevron.up.square.fill")
        cfg.imagePadding = 6
        cfg.baseBackgroundColor = EditorTheme.gutterBg
        cfg.baseForegroundColor = UIColor(white: 0.85, alpha: 1)
        cfg.cornerStyle = .capsule
        chip.configuration = cfg
        chip.layer.borderColor = UIColor(white: 0.25, alpha: 1).cgColor
        chip.layer.borderWidth = 0.5
        chip.addTarget(self, action: #selector(restoreTerminalFromChip), for: .touchUpInside)
        view.addSubview(chip)
        NSLayoutConstraint.activate([
            chip.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            chip.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            chip.heightAnchor.constraint(equalToConstant: 34),
        ])
        terminalRestoreChip = chip
    }

    @objc private func restoreTerminalFromChip() {
        terminalWindowState = .normal
        terminalContainer.isHidden = false
        swiftTermView.isHidden = false
        UIView.animate(withDuration: 0.22) {
            self.terminalContainer.alpha = 1
            self.swiftTermView.alpha = 1
            self.terminalHeightConstraint.constant = max(self.terminalNormalHeight, 180)
            self.view.layoutIfNeeded()
        }
        terminalRestoreChip?.isHidden = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Drag-to-select bridge

    /// Pan handler for our drag-to-select gesture.
    ///
    /// Three-step bridge into SwiftTerm's selection internals:
    ///   1. .began — forward `doubleTap:` to seed a word selection
    ///      at the touch point (sets selection.active=true and
    ///      populates selection.start/end). Then forward
    ///      `panSelectionHandler:` with state=.began at the same
    ///      location — this triggers the `near()` check, which
    ///      sets `selection.pivot` to the opposite end so future
    ///      .changed extends from the right anchor.
    ///   2. .changed — forward `panSelectionHandler:` with .changed
    ///      so SwiftTerm calls `selection.pivotExtend(...)`. This
    ///      no-ops if the pivot was never set, hence step 1.
    ///   3. .ended/.cancelled — forward `panSelectionHandler:` with
    ///      .ended so SwiftTerm shows its copy/lookup context menu
    ///      anchored to the selection range.
    @objc fileprivate func swiftTermDragSelectPan(_ g: UIPanGestureRecognizer) {
        let location = g.location(in: swiftTermView)
        let panSel = NSSelectorFromString("panSelectionHandler:")
        let doubleTapSel = NSSelectorFromString("doubleTap:")

        switch g.state {
        case .began:
            // Seed: selectWord at touch point + enableSelectionPanGesture
            if swiftTermView.responds(to: doubleTapSel) {
                let fake = ForcedEndedTapRecognizer()
                fake.attached = swiftTermView
                fake.fakeLocation = location
                _ = swiftTermView.perform(doubleTapSel, with: fake)
            }
            // Set the pivot so subsequent .changed events extend.
            // The .began branch in panSelectionHandler checks if hit
            // is `near()` selection.start/end — since we just seeded
            // the selection AT this location, the near-check passes
            // and pivot gets assigned to the opposite end.
            if swiftTermView.responds(to: panSel) {
                let fake = ForcedStatePanRecognizer()
                fake.attached = swiftTermView
                fake.fakeLocation = location
                fake.fakeTranslation = .zero
                fake.fakeState = .began
                _ = swiftTermView.perform(panSel, with: fake)
            }
        case .changed:
            if swiftTermView.responds(to: panSel) {
                let fake = ForcedStatePanRecognizer()
                fake.attached = swiftTermView
                fake.fakeLocation = location
                fake.fakeTranslation = g.translation(in: swiftTermView)
                fake.fakeState = .changed
                _ = swiftTermView.perform(panSel, with: fake)
            }
        case .ended, .cancelled, .failed:
            if swiftTermView.responds(to: panSel) {
                let fake = ForcedStatePanRecognizer()
                fake.attached = swiftTermView
                fake.fakeLocation = location
                fake.fakeTranslation = g.translation(in: swiftTermView)
                fake.fakeState = .ended
                _ = swiftTermView.perform(panSel, with: fake)
            }
        default:
            break
        }
    }

    // MARK: - Interrupt, font-size, menu

    /// Stop.fill / "Stop" button — interrupts the running Python
    /// task and the REPL.
    ///
    /// Previous version dispatched a small Python script
    /// (`signal.raise_signal(SIGINT)`) through PythonRuntime.shared
    /// .execute — but execute() goes through the runtime serial
    /// queue, and that queue was BUSY running the user's task. The
    /// interrupt script just sat behind it, defeating the whole
    /// purpose. Net effect: tapping Stop did nothing until the task
    /// finished on its own.
    ///
    /// Now we hit four parallel paths so the interrupt actually
    /// lands within ~1 bytecode boundary:
    ///   1. PyErr_SetInterrupt() via the C-API. Sets a flag the
    ///      interpreter checks on every bytecode tick — works
    ///      regardless of which thread holds the GIL.
    ///   2. _thread.interrupt_main() via the SAME direct-call
    ///      mechanism (PythonRuntime exposes it as raiseKeyboardInterrupt).
    ///   3. PTY 0x03 byte injected through PTYBridge → reaches the
    ///      REPL's input loop, ensuring the next prompt iteration
    ///      sees ^C even if the C-API path is stuck.
    ///   4. terminalInputField cleared so any half-typed line drops.
    /// Visible feedback: a yellow "^C — interrupted" banner echoed
    /// to the terminal so the user knows the tap registered even if
    /// the task takes a moment to actually exit.
    @objc private func terminalInterrupt() {
        // 1. Inject 0x03 into the stdin pipe FIRST so any blocked
        //    input() / os.read() in the REPL or a sub-REPL (js/node,
        //    pywebview drainer, AI mode) sees it. Patched
        //    builtins.input recognizes the byte and raises
        //    KeyboardInterrupt; the REPL's own read loop already does.
        let tv = swiftTermView
        PTYBridge.shared.send(source: tv, data: ArraySlice([0x03]))

        // 2. PyErr_SetInterrupt + file-signal backup for tight Python
        //    loops where there's no syscall to wake.
        PythonRuntime.shared.hardStopRunningTask()

        // Visible feedback so the user knows the tap registered.
        // Direct feed (not through the PTY round-trip) so it shows
        // immediately even if the read loop is backlogged.
        swiftTermView.feed(text: "\u{1b}[33m^C\u{1b}[0m\r\n")

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @objc private func terminalFontSmaller() {
        terminalFontSize = max(9, terminalFontSize - 1)
        Settings.terminalFontSize = Int(terminalFontSize)   // persist
        applyTerminalFontSize()
    }

    @objc private func terminalFontLarger() {
        terminalFontSize = min(22, terminalFontSize + 1)
        Settings.terminalFontSize = Int(terminalFontSize)   // persist
        applyTerminalFontSize()
    }

    /// Settings tab pushed a change. We're conservative about *what*
    /// we re-apply: only the cheap, idempotent things that can change
    /// at runtime (font sizes, word wrap, monaco theme). Everything
    /// else (Manim quality, autosave cadence, etc.) is read on demand
    /// from `Settings` by whichever code path uses it.
    @objc private func handleSettingsDidChange() {
        let newTerm = CGFloat(Settings.terminalFontSize)
        if newTerm != terminalFontSize {
            terminalFontSize = newTerm
            applyTerminalFontSize()
        }
        // Push editor font + theme + word wrap into Monaco. The bridge
        // is silent if the value matches what's already set, so this
        // is safe to call on every notification.
        let editorPx = Settings.editorFontSize
        monacoView.setFontSize(editorPx)
        monacoView.setWordWrap(Settings.editorWordWrap)
        let theme: String
        switch Settings.editorThemeIndex {
        case 1:  theme = "vs"            // Light
        case 2:                                    // Auto
            theme = traitCollection.userInterfaceStyle == .light ? "vs" : "vs-dark"
        default: theme = "vs-dark"      // Dark (default)
        }
        monacoView.setTheme(theme)
    }

    private func flushTermCoalesce() {
        termCoalesceScheduled = false
        guard !termCoalesceBuffer.isEmpty else { return }
        let batched = termCoalesceBuffer
        termCoalesceBuffer = ""
        swiftTermView.feed(text: batched)
    }

    private func applyTerminalFontSize() {
        let font = UIFont(name: "SFMono-Regular", size: terminalFontSize)
            ?? UIFont.monospacedSystemFont(ofSize: terminalFontSize, weight: .regular)
        swiftTermView.font = font
        terminalInputField.font = font
        // After a font change SwiftTerm recomputes cols/rows on next
        // layout; push the new size into the PTY so pip/rich/tqdm reflow.
        DispatchQueue.main.async { [weak self] in
            self?.syncTerminalSizeToPTY()
        }
    }

    /// Apply our terminal color palette + cursor style.
    ///
    /// SwiftTerm's default palette is already iTerm-like, but we override
    /// a few entries so dim/blue/green read well on our very-dark (#05060a)
    /// background. Also turn on the blinking block cursor and generous
    /// line height.
    private func configureTerminalAppearance() {
        // Terminal default colors (16-color palette — the rest are xterm256
        // or truecolor, handled by the SGR parser). Tuned for a dark bg.
        let palette: [SwiftTerm.Color] = [
            .init(red: 0x0000, green: 0x0000, blue: 0x0000),  // 0 black
            .init(red: 0xd954, green: 0x4747, blue: 0x4747),  // 1 red
            .init(red: 0x5ecf, green: 0xb852, blue: 0x6d5a),  // 2 green
            .init(red: 0xe0a5, green: 0xad26, blue: 0x5e5e),  // 3 yellow
            .init(red: 0x5a99, green: 0x88cd, blue: 0xe663),  // 4 blue
            .init(red: 0xa26b, green: 0x7e6b, blue: 0xd0a3),  // 5 magenta
            .init(red: 0x4ed5, green: 0xab42, blue: 0xc0cc),  // 6 cyan
            .init(red: 0xcccc, green: 0xcccc, blue: 0xcccc),  // 7 white
            .init(red: 0x5555, green: 0x5555, blue: 0x5555),  // 8 bright black
            .init(red: 0xf99a, green: 0x6b85, blue: 0x6b85),  // 9 bright red
            .init(red: 0x70bd, green: 0xd51f, blue: 0x80e0),  // 10 bright green
            .init(red: 0xf99a, green: 0xcb1e, blue: 0x6b85),  // 11 bright yellow
            .init(red: 0x711d, green: 0xa622, blue: 0xff6c),  // 12 bright blue
            .init(red: 0xc96d, green: 0x88cd, blue: 0xfd4e),  // 13 bright magenta
            .init(red: 0x77e6, green: 0xd1e7, blue: 0xeeee),  // 14 bright cyan
            .init(red: 0xf2f2, green: 0xf2f2, blue: 0xf2f2),  // 15 bright white
        ]
        swiftTermView.installColors(palette)
        // Native fg/bg drive the selection + cursor colors. Keep fg a
        // near-white (#e0e4ec) on our very-dark bg for easy reading.
        swiftTermView.nativeForegroundColor = UIColor(red: 0.878, green: 0.894, blue: 0.925, alpha: 1)
        swiftTermView.nativeBackgroundColor = EditorTheme.terminalBg
    }

    /// Called from viewDidLayoutSubviews — forward SwiftTerm's actual
    /// cols × rows into the PTY so pip/rich/tqdm see the real terminal
    /// size when they ask via ioctl or `os.get_terminal_size()`.
    private func syncTerminalSizeToPTY() {
        guard swiftTermView.bounds.width > 10, swiftTermView.bounds.height > 10 else { return }
        // While minimized/closed, DON'T push the tiny window size into
        // Python — we'd corrupt LINES/COLUMNS env vars and ioctl, and
        // any re-render (e.g. REPL prompt redraw) would happen at the
        // wrong width. The current Normal-state size stays in the PTY
        // until the user explicitly maximizes or resizes.
        if terminalWindowState == .minimized || swiftTermView.isHidden {
            return
        }
        let term = swiftTermView.getTerminal()
        let cols = UInt16(max(10, term.cols))
        let rows = UInt16(max(3,  term.rows))
        PTYBridge.shared.updateWindowSize(cols: cols, rows: rows)
        terminalTitleLabel.text = "CodeBench — python3.14 — \(cols)×\(rows)"
    }

    /// Whether we've fed the initial prompt yet. We need to wait for
    /// SwiftTerm to have a non-zero size or it'll render the prompt at
    /// its 2-column fallback (each char wraps onto its own line).
    private var didEmitInitialBanner = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncTerminalSizeToPTY()
        // Render the instant prompt now that SwiftTerm has its real
        // size — exactly once, on the first layout pass where the
        // terminal view actually has a non-trivial width.
        if !didEmitInitialBanner, swiftTermView.bounds.width > 80 {
            didEmitInitialBanner = true
            setTerminalInitialBanner()
        }
        // Resize the Run button's emerald gradient + output grid
        // overlay frames each time the parent bounds change.
        if let layers = runButton.layer.sublayers {
            for l in layers where l.name == "cb.run.gradient" {
                l.frame = runButton.bounds
            }
        }
        if let layers = outputPlaceholderGridLayer?.superlayer?.sublayers {
            for l in layers where l.name == "cb.output.grid" {
                l.frame = l.superlayer?.bounds ?? .zero
            }
        }
    }

    /// Apply the emerald gradient + triple shadow to the Run button.
    /// Idempotent — running it multiple times only refreshes the
    /// existing gradient sublayer rather than stacking new ones.
    private func applyRunButtonStyle() {
        let top    = UIColor(red: 0x3e/255.0, green: 0xe0/255.0, blue: 0xa8/255.0, alpha: 1.0)
        let bottom = UIColor(red: 0x22/255.0, green: 0xc0/255.0, blue: 0x8a/255.0, alpha: 1.0)
        let layerName = "cb.run.gradient"
        let existing = runButton.layer.sublayers?.first(where: { $0.name == layerName })
            as? CAGradientLayer
        let gradient = existing ?? CAGradientLayer()
        gradient.name = layerName
        gradient.colors = [top.cgColor, bottom.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.cornerRadius = 14   // capsule on 28pt height
        gradient.cornerCurve = .continuous
        if existing == nil {
            runButton.layer.insertSublayer(gradient, at: 0)
        }
        // Triple shadow per the design CSS (.ed-btn.run): outline ring,
        // drop shadow, and a 1pt inner top-highlight (the inset white
        // line). UIKit doesn't natively do inset shadows; the inset
        // highlight is faked with a thin top-aligned sublayer.
        runButton.layer.shadowColor = UIColor(red: 0x34/255.0, green: 0xd3/255.0, blue: 0x99/255.0, alpha: 1.0).cgColor
        runButton.layer.shadowOpacity = 0.35
        runButton.layer.shadowOffset = CGSize(width: 0, height: 6)
        runButton.layer.shadowRadius = 8
        runButton.layer.masksToBounds = false
    }

    /// Re-apply iPhone-friendly defaults on size-class transitions:
    /// • compact (iPhone, slim Slide Over) → files panel + output panel collapsed
    /// • regular (iPad, Split View) → restore both at design widths
    /// This is what keeps the editor usable when the user rotates,
    /// resizes the Slide Over slot, or hands the file off to an iPhone.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.horizontalSizeClass != previousTraitCollection?.horizontalSizeClass
        else { return }
        let compact = isCompactWidth
        editorFilesPanelVisible = !compact
        editorFilesWidthConstraint?.constant = compact ? 0 : 220
        editorFilesPanel.alpha = compact ? 0 : 1
        outputPanelWidthConstraint?.constant = compact ? 0 : 521
        outputPanel.isHidden = compact
        UIView.animate(withDuration: 0.2) {
            self.view.layoutIfNeeded()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Auto-focus the terminal on first appearance so the keyboard
        // is ready and typing goes straight to Python.
        if view.window != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.focusTerminal()
            }
        }
        // Recover from broken editor focus after a modal dismissal.
        // Symptom user reported: "I cannot get the cursor to be in
        // the editor box then I just have to re-open the app." The
        // cause is iOS's responder chain being left in an inconsistent
        // state when a presented sheet collapses while the editor's
        // WebView held first-responder. Forcing both Monaco's DOM
        // focus AND the WebView's first-responder ownership on every
        // viewDidAppear restores keyboard routing.
        if presentedViewController == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                // Only refocus the editor if the user wasn't actively
                // working in the terminal at the time of dismissal.
                if !self.swiftTermView.isFirstResponder {
                    self.monacoView.focusEditor()
                }
            }
        }
        // If another tab / file browser left the auto-save timer alive
        // and swapped back here, nothing to do — the timer will fire on
        // its own schedule. But we also listen for app backgrounding so
        // a swipe-to-home always flushes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(flushAutoSaveNotif),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Pull the most recent text from Monaco and flush. Async getText
        // followed by a write — the view might be deallocated before the
        // completion fires, so capture everything we need up front.
        if let url = currentFileURL {
            monacoView.getText { [url] text in
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        flushAutoSave()
    }

    // Hardware keyboard: explicit Ctrl+C / Ctrl+D / Ctrl+Z so iOS doesn't
    // fall through its standard-shortcut chain and log
    // "Unsupported action selector noop:" when no responder claims the
    // key. These send the raw byte to the PTY exactly like the on-screen
    // ⌃C button does — pressing Ctrl+C while a Python command runs
    // interrupts it via PTYBridge's 0x03 handler.
    override var keyCommands: [UIKeyCommand]? {
        let base = super.keyCommands ?? []
        // KonamiTracker was removed — Developer Panel is reachable
        // by other paths if reintroduced.

        // ⌘/ — show the keyboard-shortcuts sheet from anywhere.
        // Always available (not gated on terminal first-responder).
        let help = UIKeyCommand(input: "/", modifierFlags: .command,
                                action: #selector(showShortcutsHelp),
                                discoverabilityTitle: "Keyboard shortcuts")
        help.wantsPriorityOverSystemBehavior = true
        let alwaysOn = [help]

        // Only register these when the terminal view is first responder —
        // otherwise they'd fire while the user is typing in the code
        // editor's WebView, which has its own Ctrl+C (= copy) semantics.
        guard swiftTermView.isFirstResponder else { return base + alwaysOn }
        let c = UIKeyCommand(input: "c", modifierFlags: .control,
                             action: #selector(terminalCtrlC))
        let d = UIKeyCommand(input: "d", modifierFlags: .control,
                             action: #selector(terminalCtrlD))
        let z = UIKeyCommand(input: "z", modifierFlags: .control,
                             action: #selector(terminalCtrlZ))
        // Mac-style shortcuts for selection + copy on the terminal.
        // SwiftTerm's own `selectAll(_:)` / `copy(_:)` (UIResponder-
        // StandardEditActions overrides) do the actual work. We just
        // forward Cmd+A and Cmd+C to it here so they fire as first-
        // class keyboard commands on Mac Catalyst instead of only via
        // the edit menu (which users rarely discover).
        let cmdA = UIKeyCommand(input: "a", modifierFlags: .command,
                                action: #selector(terminalSelectAll),
                                discoverabilityTitle: "Select All in Terminal")
        let cmdC = UIKeyCommand(input: "c", modifierFlags: .command,
                                action: #selector(terminalCopy),
                                discoverabilityTitle: "Copy Terminal Selection")
        for cmd in [c, d, z, cmdA, cmdC] {
            cmd.wantsPriorityOverSystemBehavior = true
        }
        return base + alwaysOn + [c, d, z, cmdA, cmdC]
    }

    @objc private func showShortcutsHelp() {
        let vc = KeyboardShortcutsViewController()
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    // ─── Secret features wiring ──────────────────────────────────
    // Surviving editor-side secrets (the rest were pruned per user
    // request; Hidden Games moved to a tap on the BC badge in the
    // app sidebar):
    //   • 7-tap on Run button → toggle PerformanceHUD
    //   • 10× rapid Stop tap  → "I give up" defeated toast
    //   • Long-press Stop 1 s → force-kill escalation
    //
    // Removed:
    //   • 3-finger swipe-DOWN theme cycler
    //   • 3-finger swipe-UP Hidden Games launcher
    //   • Long-press 3 s terminal title bar (retro amber CRT)
    //   • December snowfall
    //   • Konami code (up-up-down-down) → Developer panel
    //   The Konami forwarding from pressesBegan is gone with it.

    private var stopRapidCount = 0
    private var stopRapidResetWork: DispatchWorkItem?
    private var runHudCount = 0
    private var runHudResetWork: DispatchWorkItem?

    private func installSecretGestures() {
        // 7-tap on Run button — must be a SEPARATE recognizer
        // because the existing target is `runTapped` (single tap).
        // We watch all taps and count rapid sequences ourselves.
        runButton.addTarget(self, action: #selector(secretRunCount),
                            for: .touchUpInside)

        // 10× rapid on the terminal Stop button (terminalInterruptButton).
        terminalInterruptButton.addTarget(self, action: #selector(secretStopCount),
                                          for: .touchUpInside)

        // Long-press the Stop button (1 s) → ESCALATE to force-kill.
        // A normal tap is just a soft interrupt (sends ^C); long-press
        // is the "I really mean it" gesture for when a render is
        // stuck in a hardware-encoder C call and the soft interrupt
        // can't deliver. Toast feedback so the user knows the
        // escalation actually fired.
        let lpStop = UILongPressGestureRecognizer(target: self,
                                                  action: #selector(forceKillStop(_:)))
        lpStop.minimumPressDuration = 1.0
        terminalInterruptButton.addGestureRecognizer(lpStop)
    }

    @objc private func secretRunCount() {
        runHudCount += 1
        runHudResetWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.runHudCount = 0 }
        runHudResetWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: w)
        if runHudCount >= 7 {
            runHudCount = 0
            PerformanceHUD.shared.toggle(in: view)
        }
    }

    @objc private func secretStopCount() {
        stopRapidCount += 1
        stopRapidResetWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.stopRapidCount = 0 }
        stopRapidResetWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
        if stopRapidCount >= 10 {
            stopRapidCount = 0
            SecretToast.defeated(on: view)
        }
    }

    // secretCycleTheme + the 3-finger swipe-down recognizer it was
    // wired to were removed per user request. SecretThemeManager
    // still exists but is no longer driven from the editor.

    // ─── Auto-preload toggle (top toolbar) ──────────────────────
    // Visual state:
    //   • ON  (filled brain.head.profile + green tint) — last model
    //     will auto-load 1.5 s after the next app launch IF available
    //     RAM is sufficient (1.7× model size).
    //   • OFF (outline icon + dim tint) — user disabled it, next
    //     launch waits for a manual model load.
    private weak var preloadToggleButton: UIButton?

    /// Single tap shows a picker listing every GGUF currently in
    /// ~/Documents/Models/ with the most-recently-used one marked.
    /// The user picks which one to load. Long-press opens the
    /// settings menu (auto-load toggle, etc.).
    @objc private func togglePreload(_ sender: UIButton) {
        let modelsDir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Models", isDirectory: true)
        let mruPath = UserDefaults.standard.string(forKey: "model.mru.path")
        let mruSlot = UserDefaults.standard.integer(forKey: "model.mru.slot")

        var availableModels: [URL] = []
        if let dir = modelsDir,
           let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) {
            availableModels = contents
                .filter { $0.pathExtension.lowercased() == "gguf" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        let sheet = UIAlertController(
            title: "Load model",
            message: availableModels.isEmpty
                ? "No GGUF models found in ~/Documents/Models/. "
                  + "Use the Models tab to download or import one."
                : "Pick a model to load right now.",
            preferredStyle: .actionSheet)

        for url in availableModels {
            let isCurrent = (url.path == mruPath)
            let sizeStr = (try? url.resourceValues(forKeys: [.fileSizeKey]))
                .flatMap { $0.fileSize }
                .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
                ?? ""
            let prefix = isCurrent ? "✓ " : "  "
            let title = "\(prefix)\(url.lastPathComponent) — \(sizeStr)"
            sheet.addAction(UIAlertAction(title: title, style: .default) { _ in
                let slot = isCurrent ? mruSlot : 0  // fallback: slot 0 if unknown
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                NotificationCenter.default.post(
                    name: .codeBenchRequestLoadModel,
                    object: nil,
                    userInfo: ["path": url.path, "slot": slot])
                self.showToast("Loading \(url.lastPathComponent)…", near: sender)
            })
        }
        sheet.addAction(UIAlertAction(title: "Open Models tab…", style: .default) { _ in
            NotificationCenter.default.post(
                name: .codeBenchOpenModelsManager, object: nil)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = sender; pop.sourceRect = sender.bounds
        }
        present(sheet, animated: true)
    }

    private func showToast(_ text: String, near anchor: UIView) {
        let label = UILabel()
        label.text = "  \(text)  "
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        label.textAlignment = .center
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: anchor.trailingAnchor),
            label.heightAnchor.constraint(equalToConstant: 28),
        ])
        UIView.animate(withDuration: 0.2, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.25, delay: 1.5, options: [], animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
    }

    private func refreshPreloadButton(_ btn: UIButton) {
        let enabled = !ModelPrewarmer.isDisabled
        // Different icons make the toggle state obvious at a glance.
        // Filled = ON, regular = OFF. (Earlier this used the same
        // icon for both states, making the button look broken — the
        // tap WAS working but the visual didn't change.)
        let iconName = enabled ? "brain.head.profile.fill" : "brain.head.profile"
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        let icon = UIImage(systemName: iconName, withConfiguration: cfg)
            ?? UIImage(systemName: enabled ? "bolt.fill" : "bolt.slash",
                       withConfiguration: cfg)
        btn.setImage(icon, for: .normal)
        btn.tintColor = enabled ?
            UIColor(red: 0.30, green: 0.78, blue: 0.45, alpha: 1) :
            UIColor(white: 0.45, alpha: 1)
        let mru = UserDefaults.standard.string(forKey: "model.mru.path")
            .flatMap { ($0 as NSString).lastPathComponent } ?? "no model yet"
        btn.accessibilityLabel = enabled
            ? "Auto-load on next launch: \(mru)"
            : "Auto-load disabled"
        // Long-press shows path detail. Critical: `cancelsTouchesInView
        // = false` — otherwise the long-press recognizer eats every
        // touch DOWN before the button's `touchUpInside` event can
        // fire, making the button look unresponsive on tap.
        btn.gestureRecognizers?.forEach {
            if $0 is UILongPressGestureRecognizer { btn.removeGestureRecognizer($0) }
        }
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(showPreloadInfo))
        lp.minimumPressDuration = 0.6
        lp.cancelsTouchesInView = false
        lp.delaysTouchesBegan = false
        lp.delaysTouchesEnded = false
        btn.addGestureRecognizer(lp)
    }

    @objc private func showPreloadInfo(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let btn = g.view as? UIButton else { return }
        let mru = UserDefaults.standard.string(forKey: "model.mru.path")
        let mruName = mru.flatMap { ($0 as NSString).lastPathComponent } ?? "(none)"
        let enabled = !ModelPrewarmer.isDisabled
        let sheet = UIAlertController(
            title: "Model preload",
            message: "Last used: \(mruName)",
            preferredStyle: .actionSheet)
        if mru != nil {
            sheet.addAction(UIAlertAction(title: "Load now", style: .default) { [weak self] _ in
                self?.togglePreload(btn)
            })
        }
        let toggleTitle = enabled ? "Auto-load on next launch: ON" : "Auto-load on next launch: OFF"
        sheet.addAction(UIAlertAction(title: toggleTitle, style: .default) { [weak self] _ in
            if enabled { ModelPrewarmer.disable() } else { ModelPrewarmer.enable() }
            self?.refreshPreloadButton(btn)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = btn; pop.sourceRect = btn.bounds
        }
        present(alert: sheet)
    }
    private func present(alert: UIAlertController) { present(alert, animated: true) }

    @objc private func forceKillStop(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        PythonRuntime.shared.forceKillRunningTask()
        swiftTermView.feed(text: "\r\n\u{1b}[31m^C (force-kill)\u{1b}[0m\r\n")
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    // ─── Folder mount request poller ─────────────────────────
    // Python builtins `mount` / `umount` / `mounts` write a request
    // JSON to $TMPDIR/codebench_mounts_request.txt; we poll for it,
    // dispatch to FolderMountManager (which may present a system
    // picker on the main thread), and write the response back.

    // ─── Fine-tune request poller ────────────────────────────
    private var finetunePollTimer: Timer?
    private var finetuneReqURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codebench_finetune_request.json")
    }
    private var finetuneProgURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codebench_finetune_progress.json")
    }
    private var finetuneResURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codebench_finetune_result.json")
    }
    private func installFinetuneRequestPoller() {
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.handleFinetuneRequestIfAny()
            self?.handleLoraRequestIfAny()
        }
        RunLoop.main.add(t, forMode: .common)
        finetunePollTimer = t
    }
    // ─── LoRA adapter attach/detach poller ────────────────────
    // Python's `/lora` slash command writes a JSON request file;
    // we apply the adapter to the live LlamaRunner and respond.

    private var attachedLoraAdapter: OpaquePointer?
    private var loraReqURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codebench_lora_request.json")
    }
    private var loraRespURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codebench_lora_response.json")
    }

    private func handleLoraRequestIfAny() {
        let req = loraReqURL
        guard FileManager.default.fileExists(atPath: req.path),
              let data = try? Data(contentsOf: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        try? FileManager.default.removeItem(at: req)
        guard let runner = llamaRunner else {
            writeJSON(["ok": false, "error": "no model loaded"], to: loraRespURL)
            return
        }
        switch obj["action"] as? String ?? "" {
        case "attach":
            let path = obj["path"] as? String ?? ""
            let scale = Float(obj["scale"] as? Double ?? 1.0)
            // Detach any existing adapter first.
            if let prev = attachedLoraAdapter {
                runner.detachLoraAdapter(prev)
                attachedLoraAdapter = nil
            }
            if let new = runner.applyLoraAdapter(path: path, scale: scale) {
                attachedLoraAdapter = new
                // Include the active model's path so the Python
                // side can sync its `_LOADED_MODEL` flag — without
                // that sync, the chat path refuses with "no model
                // loaded" even though Swift can serve responses.
                let mru = UserDefaults.standard.string(forKey: "model.mru.path") ?? ""
                writeJSON(["ok": true, "model_path": mru], to: loraRespURL)
            } else {
                writeJSON(["ok": false], to: loraRespURL)
            }
        case "detach":
            if let cur = attachedLoraAdapter {
                runner.detachLoraAdapter(cur)
                attachedLoraAdapter = nil
                writeJSON(["ok": true], to: loraRespURL)
            } else {
                writeJSON(["ok": false], to: loraRespURL)
            }
        default:
            writeJSON(["ok": false, "error": "unknown action"], to: loraRespURL)
        }
    }

    private func handleFinetuneRequestIfAny() {
        let req = finetuneReqURL
        guard FileManager.default.fileExists(atPath: req.path),
              let data = try? Data(contentsOf: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        try? FileManager.default.removeItem(at: req)

        guard let runner = llamaRunner,
              runner.loadedModelPointer != nil else {
            writeJSON(["ok": false,
                       "error": "no model loaded — use Models tab to load a GGUF first"],
                      to: finetuneResURL)
            return
        }
        // Resolve the model URL + its original load config so we can
        // (1) reload it in training-mode (non-mmap, F32 KV cache),
        // (2) train, (3) restore inference-mode after.
        let mruPath = UserDefaults.standard.string(forKey: "model.mru.path") ?? ""
        guard !mruPath.isEmpty,
              FileManager.default.fileExists(atPath: mruPath) else {
            writeJSON(["ok": false,
                       "error": "could not resolve current model's file path on disk"],
                      to: finetuneResURL)
            return
        }
        let modelURL = URL(fileURLWithPath: mruPath)
        // Pull the original Config from the LlamaRunner's last load.
        // Using its defaults if exposure isn't there is fine — the
        // restore path just reloads inference mode.
        let baseConfig = LlamaRunner.Config()

        let dataPath = obj["data"] as? String ?? ""
        let outPath  = obj["out"] as? String ?? ""
        let epochs   = obj["epochs"] as? Int ?? 3
        let lr       = Float(obj["lr"] as? Double ?? 1e-4)

        // LoRA training pipeline via QVAC's bridge:
        //   1. Free the inference model+context (the bridge loads its
        //      own — keeping both alive would OOM).
        //   2. Run `llama_swift_run_lora_finetune` which builds its
        //      own training context, trains on GPU with the bundled
        //      Metal backward kernels, and saves a LoRA adapter.
        //   3. Reload the inference model when done.
        //
        // The output is a SMALL adapter file (1-50 MB) — not a new
        // full GGUF. Apply at inference time via llama's adapter API.
        appendToTerminal("\u{1b}[36m[finetune]\u{1b}[0m freeing inference "
                         + "context and starting LoRA training "
                         + "(GPU via Metal backward kernels)…\r\n",
                         isError: false)

        // Step 1: tear down inference. The bridge runs its own model
        // load inside llama_swift_run_lora_finetune; we just need to
        // free our pointers first.
        runner.unloadModel()

        // Output an .lora.gguf next to where the user requested.
        let adapterPath = outPath.hasSuffix(".gguf")
            ? outPath.replacingOccurrences(of: ".gguf", with: ".lora.gguf")
            : outPath + ".lora.gguf"

        // Wipe any previous progress log so the Python tail starts
        // from zero this run.
        try? FileManager.default.removeItem(at: finetuneProgURL)
        LlamaFinetuner.shared.finetune(
            modelPath: modelURL.path,
            dataPath: dataPath,
            outAdapterPath: adapterPath,
            epochs: epochs,
            learningRate: lr,
            onProgress: { [weak self] p in
                // APPEND a JSONL record per log line so the Python
                // side can tail and stream each event in real time.
                guard let self else { return }
                self.appendFinetuneProgress(p.logLine)
            },
            completion: { [weak self] result in
                guard let self else { return }
                // Step 3: reload inference regardless of training outcome.
                runner.restoreInferenceMode { _ in
                    switch result {
                    case .success(let url):
                        self.writeJSON(["ok": true, "path": url.path],
                                       to: self.finetuneResURL)
                    case .failure(let e):
                        self.writeJSON(["ok": false,
                                        "error": e.localizedDescription],
                                       to: self.finetuneResURL)
                    }
                }
            })
    }
    private func writeJSON(_ obj: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Append one JSONL line `{"log": "..."}` to the progress file.
    /// The Python `finetune` builtin tails this file and prints each
    /// new record as it arrives so users see live training progress.
    private func appendFinetuneProgress(_ line: String) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["log": line])
        else { return }
        let line = data + Data([0x0a])    // append \n
        let path = finetuneProgURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: line)
            return
        }
        if let h = FileHandle(forWritingAtPath: path) {
            defer { try? h.close() }
            try? h.seekToEnd()
            try? h.write(contentsOf: line)
        }
    }

    private var mountPollTimer: Timer?
    private func installMountRequestPoller() {
        // Touch the shared instance — its init() re-resolves every
        // saved bookmark and calls startAccessingSecurityScopedResource
        // so previously-mounted folders are immediately reachable
        // via ~/Documents/Mounts/<label> on this launch.
        _ = FolderMountManager.shared

        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.handleMountRequestIfAny()
        }
        RunLoop.main.add(t, forMode: .common)
        mountPollTimer = t
    }

    private var mountReqURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codebench_mounts_request.txt")
    }
    private var mountRespURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codebench_mounts_response.txt")
    }

    private func handleMountRequestIfAny() {
        let req = mountReqURL
        guard FileManager.default.fileExists(atPath: req.path),
              let data = try? Data(contentsOf: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        try? FileManager.default.removeItem(at: req)
        let action = (obj["action"] as? String) ?? ""
        switch action {
        case "pick":
            let label = obj["label"] as? String
            FolderMountManager.shared.presentPicker(
                from: self, label: label?.isEmpty == false ? label : nil
            ) { result in
                switch result {
                case .success(let m):
                    self.writeMountResp([
                        "ok": true,
                        "label": m.label,
                        "path": m.resolvedURL?.path ?? "?",
                    ])
                case .failure(let e):
                    self.writeMountResp([
                        "ok": false,
                        "error": e.localizedDescription,
                    ])
                }
            }
        case "umount":
            let label = (obj["label"] as? String) ?? ""
            let ok = FolderMountManager.shared.unmount(label: label)
            writeMountResp(["ok": ok, "error": ok ? "" : "no such mount"])
        case "list":
            let lines = FolderMountManager.shared.describe()
            writeMountResp(["lines": lines])
        default:
            writeMountResp(["ok": false, "error": "unknown action"])
        }
    }

    private func writeMountResp(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: mountRespURL, options: .atomic)
    }

    // secretOpenGames / secretRetroToggle / applySecretTheme +
    // the gestures that triggered them (3-finger swipe-up, terminal
    // title-bar long-press) were removed per user request. Hidden
    // Games is now launched from the BC badge in the app sidebar.

    /// Select all visible terminal text + scrollback. Mirrors SwiftTerm's
    /// own `selectAll(_:)` override (UIResponderStandardEditActions).
    /// After this, Cmd+C copies the selection to the clipboard.
    @objc private func terminalSelectAll() {
        swiftTermView.selectAll(nil)
    }

    /// Copy whatever is currently selected in the terminal. If nothing
    /// is selected, SwiftTerm's own copy(_:) is a no-op — in that case
    /// we fall back to copying the entire mirrored terminal log buffer
    /// so Cmd+C is always useful.
    @objc private func terminalCopy() {
        if swiftTermView.selectionActive {
            swiftTermView.copy(nil)
        } else if !terminalLogBuffer.isEmpty {
            UIPasteboard.general.string = terminalLogBuffer
            // Brief on-screen flash so the user knows it worked — the
            // clipboard write itself is silent.
            appendToTerminal("\n[copied \(terminalLogBuffer.count) chars to clipboard]\n",
                             isError: false)
        }
    }

    @objc private func terminalCtrlC() {
        // Route through LineBuffer.handle() so the full Ctrl-C path fires
        // — including AI-mode behavior (palette dismissal + writing
        // `ai_cancel.txt` so AIEngine can stop the LlamaRunner during
        // generation). The previous version sent 0x03 straight to the
        // PTY pipe, bypassing LineBuffer entirely, which is why Ctrl-C
        // didn't cancel generation in the `ai` REPL — Python was polling
        // Swift's response file, not reading stdin, so the raw byte had
        // nothing to do.
        let tv = swiftTermView
        LineBuffer.shared.handle(bytes: ArraySlice([0x03]),
                                 terminalView: tv,
                                 pipeWrite: { bytes in
            PTYBridge.shared.send(source: tv, data: ArraySlice(bytes))
        })
        PythonRuntime.shared.interruptPythonMainThread()
    }

    @objc private func terminalCtrlD() {
        PTYBridge.shared.send(source: swiftTermView, data: ArraySlice([0x04]))
    }

    @objc private func terminalCtrlZ() {
        PTYBridge.shared.send(source: swiftTermView, data: ArraySlice([0x1a]))
    }

    @objc private func flushAutoSaveNotif() {
        if let url = currentFileURL {
            monacoView.getText { [url] text in
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        flushAutoSave()
    }

    @objc private func focusTerminal() {
        // Don't early-return on isFirstResponder: the soft keyboard can
        // be dismissed (swipe down, external kb disconnect) while the
        // view still thinks it's first responder. Resign then re-become
        // so the keyboard reliably re-appears on every tap.
        if swiftTermView.isFirstResponder {
            swiftTermView.resignFirstResponder()
        }
        let ok = swiftTermView.becomeFirstResponder()
        NSLog("[term] becomeFirstResponder returned \(ok)")
        // On some iOS versions SwiftTerm's UITextInput surface needs a
        // reloadInputViews() kick to actually present the keyboard.
        swiftTermView.reloadInputViews()
    }

    /// Keyboard-avoidance for the terminal. Without this, when the
    /// user taps the terminal on an iPhone / Magic-Keyboard-less iPad,
    /// the software keyboard pops up from the bottom and covers the
    /// most recent prompt (`euler@Eulers-iPad ~/Workspace %`), which
    /// is always at the bottom of the terminal. The user then sees
    /// an empty-looking terminal and doesn't realise the REPL is
    /// waiting for input.
    ///
    /// Fix: observe keyboard-frame notifications and shrink the view's
    /// usable area (`additionalSafeAreaInsets.bottom`) by the
    /// keyboard's overlap. `mainStack` (holding the editor + terminal)
    /// re-lays-out automatically via its safe-area-bounded constraints,
    /// so the terminal contracts and the prompt stays visible. Then
    /// scroll SwiftTerm to the bottom so the latest line is on screen.
    private func setupKeyboardAvoidance() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyboardFrameWillChange(_:)),
                       name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                       name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardFrameWillChange(_ note: Notification) {
        guard let info = note.userInfo,
              let endFrameRaw = info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else { return }
        let endFrame = endFrameRaw.cgRectValue
        // Convert the keyboard frame into our view's coordinate space
        // — it arrives in screen coords and we care about how much of
        // OUR view it actually covers (Stage Manager / Split View /
        // iPhone landscape etc. all affect the overlap).
        let converted = view.convert(endFrame, from: nil)
        let overlap = max(0, view.bounds.maxY - converted.minY)
        // Subtract the existing safe-area bottom (home-indicator inset)
        // — iOS already accounts for that, we only want the ADDITIONAL
        // inset the keyboard introduces.
        let delta = max(0, overlap - view.safeAreaInsets.bottom + additionalSafeAreaInsets.bottom)
        let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
        let curveRaw = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? UIView.AnimationCurve.easeInOut.rawValue
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: UInt(curveRaw << 16)),
            animations: {
                self.additionalSafeAreaInsets.bottom = delta
                self.view.layoutIfNeeded()
            },
            completion: { _ in
                // After layout settles, pull the terminal's scroll
                // down so the most recent prompt line is still in view.
                // SwiftTerm doesn't expose a direct scrollToBottom API,
                // but feeding an empty string forces a redraw that
                // respects the current visible range.
                if self.swiftTermView.isFirstResponder {
                    self.swiftTermView.feed(text: "")
                }
            })
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval) ?? 0.25
        UIView.animate(withDuration: duration) {
            self.additionalSafeAreaInsets.bottom = 0
            self.view.layoutIfNeeded()
        }
    }

    /// When a magic keyboard is connected we hide SwiftTerm's ESC/F1-F12
    /// accessory bar entirely — those keys are on the hardware. When no
    /// keyboard is attached, we install a minimal 3-button bar with
    /// Esc / Tab / Ctrl (the ones you actually need in a Python REPL
    /// but soft iOS keyboards don't provide).
    @objc private func updateTerminalAccessoryForKeyboardState() {
        let hasMagic = GCKeyboard.coalesced != nil
        if hasMagic {
            swiftTermView.inputAccessoryView = nil
            NSLog("[term] magic keyboard present — accessory bar hidden")
        } else {
            if !(swiftTermView.inputAccessoryView is MinimalTerminalAccessory) {
                let bar = MinimalTerminalAccessory { [weak self] bytes in
                    PTYBridge.shared.send(data: bytes)
                    // Keep focus after pressing a toolbar key
                    _ = self?.swiftTermView.becomeFirstResponder()
                }
                swiftTermView.inputAccessoryView = bar
                NSLog("[term] no magic keyboard — minimal accessory bar installed")
            }
        }
        // Force the input views to refresh
        if swiftTermView.isFirstResponder {
            swiftTermView.reloadInputViews()
        }
    }

    /// Ellipsis menu: reset shell, clear history, export log, etc.
    @objc private func showTerminalMenu(_ sender: UIButton) {
        let alert = UIAlertController(title: "Terminal", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Reset Python shell (new namespace)", style: .destructive) { [weak self] _ in
            self?.resetPythonShell()
        })
        alert.addAction(UIAlertAction(title: "Clear command history", style: .destructive) { [weak self] _ in
            self?.terminalHistory.removeAll()
            self?.terminalHistoryIndex = 0
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        })
        alert.addAction(UIAlertAction(title: "Export log to Documents/", style: .default) { [weak self] _ in
            self?.exportTerminalLog()
        })
        alert.addAction(UIAlertAction(title: "Re-export TMPDIR / fix sandbox", style: .default) { [weak self] _ in
            self?.diagnoseTerminalEnv()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // iPad popover
        if let popover = alert.popoverPresentationController {
            popover.sourceView = sender
            popover.sourceRect = sender.bounds
            popover.permittedArrowDirections = [.up]
        }
        present(alert, animated: true)
    }

    private func resetPythonShell() {
        let code = """
        import __main__, sys
        # Reset __main__ to a fresh dict (keeps __builtins__).
        for k in list(__main__.__dict__):
            if not k.startswith('__'):
                del __main__.__dict__[k]
        # Drop the shell's cached state so `offlinai_shell.shell.pending`
        # clears on next use.
        sys.modules.pop('offlinai_shell', None)
        print('\\x1b[32m✓ Python shell reset — all user bindings cleared.\\x1b[0m')
        """
        setTerminalStatus(.running)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = PythonRuntime.shared.execute(code: code) { chunk in
                DispatchQueue.main.async { self?.appendToTerminal(chunk, isError: false) }
            }
            DispatchQueue.main.async {
                self?.setTerminalStatus(.ready)
                self?.terminalContinuation = false
                self?.refreshTerminalPrompt()
            }
        }
    }

    private func exportTerminalLog() {
        let text = terminalLogBuffer
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = docs.appendingPathComponent("terminal_\(stamp).log")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            appendToTerminal("\n[log] saved to \(url.path)\n", isError: false)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            appendToTerminal("\n[log] failed: \(error.localizedDescription)\n", isError: true)
        }
    }

    private func diagnoseTerminalEnv() {
        let code = """
        import os, sys, tempfile
        print(f'Python:   {sys.version.split()[0]}')
        print(f'platform: {sys.platform}')
        print(f'cwd:      {os.getcwd()}')
        print(f'HOME:     {os.environ.get(\"HOME\", \"?\")}')
        print(f'TMPDIR:   {os.environ.get(\"TMPDIR\", \"?\")}')
        print(f'gettempdir(): {tempfile.gettempdir()}')
        print(f'PYTHONPATH entries: {len(sys.path)}')
        for p in sys.path[:5]:
            print(f'  {p}')
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = PythonRuntime.shared.execute(code: code) { chunk in
                DispatchQueue.main.async { self?.appendToTerminal(chunk, isError: false) }
            }
        }
    }

    // MARK: - Thinking Pill (ChatGPT-style collapsible)

    private struct ThinkingPillViews {
        let container: UIView
        let label: UILabel       // "Thought for Xs >"
        let detail: UILabel      // collapsed thinking content
    }

    private func makeThinkingPill() -> ThinkingPillViews {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // "Thought for Xs >" label — tappable to expand/collapse
        let pillLabel = UILabel()
        pillLabel.text = "Thinking..."
        pillLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        pillLabel.textColor = UIColor(white: 0.50, alpha: 1)
        pillLabel.translatesAutoresizingMaskIntoConstraints = false

        // Detail text (thinking content — hidden by default, shown on tap)
        let detailLabel = UILabel()
        detailLabel.text = ""
        detailLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = UIColor(white: 0.40, alpha: 1)
        detailLabel.numberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.isHidden = true  // Collapsed by default
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(pillLabel)
        container.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            pillLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            pillLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            pillLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),

            detailLabel.topAnchor.constraint(equalTo: pillLabel.bottomAnchor, constant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            detailLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])

        // Tap to expand/collapse thinking content
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleThinkingPill(_:)))
        container.addGestureRecognizer(tap)
        container.isUserInteractionEnabled = true

        return ThinkingPillViews(container: container, label: pillLabel, detail: detailLabel)
    }

    @objc private func toggleThinkingPill(_ gesture: UITapGestureRecognizer) {
        guard let container = gesture.view else { return }
        // Find the detail label (second subview)
        guard container.subviews.count >= 2 else { return }
        let detailLabel = container.subviews[1]
        UIView.animate(withDuration: 0.2) {
            detailLabel.isHidden.toggle()
            self.chatStackView.layoutIfNeeded()
        }
        scrollChatToBottom()
    }

    // MARK: - Helpers

    /// Push text into the SwiftTerm xterm emulator. ANSI escape codes,
    /// `\r` line-overwrite, colors, bold, and cursor positioning are all
    /// handled natively by SwiftTerm's VT100 state machine — no more
    /// NSAttributedString reimplementation. We also keep a mirror in
    /// `terminalLogBuffer` so Copy and Export-log still work.
    /// Synchronous wrapper around BusytexEngine.compile for use from
    /// the Run-button path (which already runs on a background queue).
    /// Writes the user's source to a temp .tex, drives busytex's WASM
    /// pdftex through the same path the in-app `pdflatex` builtin
    /// uses, and returns the resulting PDF path + log + status code.
    /// Times out after 90 s — long enough for cold-start busytex to
    /// preload its texmf, generous enough for a real-doc compile.
    func compileLaTeXSync(source: String) -> (status: Int, log: String, pdfPath: String?) {
        let tmpDir = NSTemporaryDirectory().appending("codebench_latex/")
        try? FileManager.default.createDirectory(atPath: tmpDir,
            withIntermediateDirectories: true)
        let stem = "doc_\(Int(Date().timeIntervalSince1970))"
        let pdfOut = tmpDir + stem + ".pdf"

        let sem = DispatchSemaphore(value: 0)
        var status = -1
        var logText = ""
        var pdfPath: String? = nil
        BusytexEngine.shared.compile(
            texSource: source,
            mainFileName: stem + ".tex",
            workingDir: URL(fileURLWithPath: tmpDir, isDirectory: true)
        ) { rc, log, pdfData in
            status = rc
            logText = log
            if rc == 0, let data = pdfData {
                do {
                    try data.write(to: URL(fileURLWithPath: pdfOut))
                    pdfPath = pdfOut
                } catch {
                    logText += "\nPDF write failed: \(error)"
                }
            }
            sem.signal()
        }
        // 90 s ceiling for cold-start busytex (WASM + texmf preload
        // takes 30 s, then a complex doc 30-60 s). Anything longer
        // is a hung WASM call we should bail on.
        _ = sem.wait(timeout: .now() + 90)
        return (status, logText, pdfPath)
    }

    // Coalesce buffer — multiple appendToTerminal calls within a
    // single main-loop tick get merged into one SwiftTerm feed, which
    // collapses N layout passes into 1. Verbose scripts (numpy errors,
    // tqdm with mininterval=0, "for line in lines: print(line)") were
    // spending more time in SwiftTerm's reflow than in their own logic.
    private var termCoalesceBuffer = ""
    private var termCoalesceScheduled = false

    private func appendToTerminal(_ text: String, isError: Bool) {
        // If the caller tagged this as an error, bracket in red so stuff
        // without its own escape codes still stands out.
        let wrapped: String
        if isError && !text.contains("\u{1b}[") {
            wrapped = "\u{1b}[31m" + text + "\u{1b}[0m"
        } else {
            wrapped = text
        }
        // VT100 line-ending normalization. Python's `print` emits a
        // bare `\n`, but a real terminal expects `\r\n` (LF moves the
        // cursor DOWN, CR returns it to column 0). Without the CR,
        // each new line started at the column where the previous one
        // ended — producing the stair-step output the user reported.
        //
        // Steps:
        //   1. Collapse existing `\r\n` to `\n` so we don't
        //      double-emit `\r\r\n`.
        //   2. Expand every `\n` (that isn't preceded by `\r`) to
        //      `\r\n`.
        //   3. Bare `\r` (no following `\n`) is preserved as-is —
        //      tqdm/rich use it for in-place progress bars and need
        //      the cursor to stay on the current line.
        let normalized = wrapped
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        // Append to the coalesce buffer, schedule a single feed on
        // the next runloop tick. Small writes (<512 B) batch; larger
        // ones flush immediately so progress bars don't lag.
        termCoalesceBuffer += normalized
        if termCoalesceBuffer.count > 4096 {
            flushTermCoalesce()
        } else if !termCoalesceScheduled {
            termCoalesceScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.flushTermCoalesce()
            }
        }
        // Mirror keeps the ORIGINAL text (no CR injection) so
        // anything that copies the buffer (Cmd+C / share) gets the
        // clean output users actually wrote.
        terminalLogBuffer.append(text)
        // Cap the mirror to ~1MB so long-running sessions don't balloon
        // memory; drop the oldest half when we hit the limit.
        if terminalLogBuffer.count > 1_000_000 {
            let cut = terminalLogBuffer.index(terminalLogBuffer.startIndex,
                                              offsetBy: terminalLogBuffer.count / 2)
            terminalLogBuffer = String(terminalLogBuffer[cut...])
        }
    }

    /// Internal-tag prefixes whose lines are diagnostic noise (manim
    /// font setup, fallback path-discovery probes, py-exec timing) —
    /// useful while debugging from Xcode but pure clutter in the
    /// in-app terminal where users are actually watching their
    /// program run. Lines matching any of these get NSLog'd (so they
    /// surface in the Xcode console / Console.app) and dropped from
    /// the terminal feed.
    private static let _terminalNoisePrefixes: [String] = [
        "[diag]", "[fallback]",
        "[py-exec]", "[manim-font]", "[manim rendered]",
        // Per-frame encode chatter from the iOS-patched scene_file_writer
        // (see app_packages/.../manim/scene/scene_file_writer.py — 21
        // print sites that write at frame / batch / partial granularity).
        // For a 119-animation render that's ≈800 lines of pure noise;
        // route to NSLog so Xcode console keeps it but the user-visible
        // terminal stays focused on print() output.
        "[manim-debug]",
    ]

    /// Like `appendToTerminal`, but routes lines that match the
    /// internal-debug prefixes (see `_terminalNoisePrefixes`) to
    /// NSLog instead of the terminal. Use for output streamed from
    /// the Python runtime — keeps the user-visible terminal focused
    /// on what their script actually printed.
    /// Carry-over for partial lines between PTY chunks. PTY reads can
    /// arrive on any byte boundary, so a "[plot saved] /path/foo.html\n"
    /// line might split across two onOutputBytes callbacks. We append
    /// each chunk's tail to this buffer and only consume bytes up to
    /// the last newline.
    private var ptyPlotScanBuffer: String = ""
    private var toolOutputDirWatcher: DispatchSourceFileSystemObject?
    private var toolOutputDirFD: Int32 = -1
    private var lastShownChartTime: Date = .distantPast
    private var lastShownChartPath: String = ""
    /// Currently-presented preview sheet on iPhone. The inline
    /// outputPanel is hidden on compact width (would take the whole
    /// screen), so charts are surfaced as a half-sheet modal that
    /// the user can dismiss. Kept around so we don't re-present
    /// the same chart multiple times if showImageOutput is called
    /// repeatedly with the same path (e.g. dir-watch + PTY scanner
    /// both fire).
    private weak var presentedPreviewSheet: PreviewSheetViewController?
    /// Paths currently being polled for write-completion. The dir-watch
    /// fs-event fires when a file's inode is created (size 0), but does
    /// NOT re-fire when its content is later written — DispatchSource's
    /// .write event on a directory only tracks add/remove/rename, not
    /// content growth of existing entries. So when the size-guard
    /// rejects a file as mid-write, we add it here and poll until it's
    /// fully written. Lets slow writes (e.g. heavy plotly HTML that
    /// takes ~80s to serialize) still surface in the preview pane.
    private var pollingChartPaths: Set<String> = []

    /// Scan a PTY output chunk for `[plot saved] <path>` lines and
    /// route them to the preview pane. Run on whatever thread the PTY
    /// reader calls us from; we hop to main before touching UIKit.
    ///
    /// PTYs translate "\n" to "\r\n" by default (onlcr), so each line
    /// arrives as "…\r\n". We trim with `.whitespacesAndNewlines` (not
    /// `.whitespaces` — that doesn't strip "\r") to keep the extracted
    /// path from having a trailing carriage return that breaks
    /// FileManager.fileExists.
    private func scanTerminalChunkForPlot(_ chunk: String) {
        ptyPlotScanBuffer.append(chunk)
        // Process complete lines only; keep any trailing partial line
        // in the buffer for the next chunk.
        let lastNL = ptyPlotScanBuffer.lastIndex(of: "\n")
        guard let lastNL else {
            // No newline yet — wait for more bytes. Bound the buffer
            // so a stuck partial line can't grow without limit.
            if ptyPlotScanBuffer.count > 8192 {
                ptyPlotScanBuffer.removeFirst(ptyPlotScanBuffer.count - 4096)
            }
            return
        }
        let processable = ptyPlotScanBuffer[..<lastNL]
        ptyPlotScanBuffer = String(ptyPlotScanBuffer[ptyPlotScanBuffer.index(after: lastNL)...])

        // Markers we route to the preview pane. Both come from
        // sitecustomize.py / PythonRuntime.swift's _show_hook variants.
        // [plot saved] — matplotlib/plotly figures
        // [manim rendered] — manim Scene.render output
        let markers = ["[plot saved] ", "[manim rendered] "]
        for lineSub in processable.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            // Strip ANSI escape codes (CSI sequences like \x1b[2K
            // clear-line, color codes, etc.) BEFORE the prefix check.
            // PTY output frequently has prompt-redraw escapes
            // prefixing user output lines; without stripping them,
            // `[plot saved]` arrives as `\x1b[2K[plot saved] /…` and
            // hasPrefix returns false even though the marker is there.
            let lineStr = String(lineSub)
            let stripped = Self.stripAnsiEscapes(lineStr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for marker in markers {
                guard stripped.hasPrefix(marker) else { continue }
                let path = String(stripped.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard path.hasPrefix("/"),
                      FileManager.default.fileExists(atPath: path) else { continue }
                NSLog("[chart-watch] (pty) parsed marker=%@ path=%@",
                      marker.trimmingCharacters(in: .whitespaces), path)
                DispatchQueue.main.async { [weak self] in
                    self?.tryShowChart(path: path, source: "pty")
                }
                break  // matched one marker; next line
            }
        }
    }

    /// Remove ANSI escape sequences (CSI/SGR/OSC) from a string. Used
    /// before parsing tagged marker lines out of PTY output where
    /// prompt-redraw and color codes can prefix the literal text.
    /// Handles the two common shapes:
    ///   • CSI:  ESC '[' <params> <letter>           — e.g. \x1b[2K, \x1b[31m
    ///   • OSC:  ESC ']' <text> ESC '\' (or BEL)    — e.g. \x1b]0;title\x07
    /// Anything else with ESC is left intact (vt100 charset selects etc.).
    private static func stripAnsiEscapes(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\u{1B}", i + 1 < chars.count {
                let nxt = chars[i + 1]
                if nxt == "[" {
                    // CSI — skip until a letter (final byte in 0x40–0x7E)
                    i += 2
                    while i < chars.count {
                        let cc = chars[i]
                        i += 1
                        if let v = cc.asciiValue, v >= 0x40 && v <= 0x7E { break }
                    }
                    continue
                } else if nxt == "]" {
                    // OSC — skip until BEL (0x07) or ESC '\'
                    i += 2
                    while i < chars.count {
                        let cc = chars[i]
                        if cc == "\u{07}" { i += 1; break }
                        if cc == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "\\" {
                            i += 2; break
                        }
                        i += 1
                    }
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Idempotent — opens a DispatchSource on the ToolOutputs dir
    /// and watches for chart files appearing. Each new chart appearing
    /// in the directory is loaded into the preview pane, even if the
    /// PTY scanner missed the `[plot saved]` line (e.g. when the script
    /// crashes mid-print, or when stdout is captured by something other
    /// than the PTY). This is the safety net for the terminal preview.
    private func startToolOutputDirectoryWatcher() {
        guard toolOutputDirWatcher == nil else { return }
        guard let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask).first else { return }
        let toolDir = documents.appendingPathComponent("ToolOutputs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: toolDir, withIntermediateDirectories: true)
        let fd = open(toolDir.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[chart-watch] open(%@) failed: %d", toolDir.path, errno)
            return
        }
        toolOutputDirFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .global(qos: .utility))
        src.setEventHandler { [weak self] in
            self?.onToolOutputDirectoryChanged()
        }
        src.setCancelHandler { [weak self] in
            if let f = self?.toolOutputDirFD, f >= 0 { close(f) }
            self?.toolOutputDirFD = -1
        }
        src.resume()
        toolOutputDirWatcher = src
        // Seed the lastShownChartTime to "now" so pre-existing files
        // from previous sessions don't immediately surface as a fresh
        // chart on app start.
        lastShownChartTime = Date()
    }

    /// Called from the dir-watch DispatchSource when ToolOutputs/
    /// changes. Walks for a chart-like file modified more recently
    /// than our last-shown timestamp and loads it.
    private func onToolOutputDirectoryChanged() {
        guard let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask).first else { return }
        let toolDir = documents.appendingPathComponent("ToolOutputs", isDirectory: true)
        // Diagnostic: log every fs-event firing so we can tell (in
        // Xcode console) whether the watcher itself triggered. If the
        // user reports "preview didn't update" and this log is absent,
        // the DispatchSource didn't fire at all (likely a closed fd
        // or watcher cancellation) — investigate ``startToolOutputDirectoryWatcher``.
        // If this log fires but no ``[chart-watch] (dir-watch) loading``
        // follows, the file was filtered out (size guard, cutoff
        // mismatch, wrong extension, partial_movie_files path).
        NSLog("[chart-watch] dir-event fired, scanning %@", toolDir.path)
        let mediaExts: Set<String> = ["html", "png", "jpg", "jpeg", "gif", "pdf",
                                      "mp4", "mov", "webm", "m4v"]
        let enumerator = FileManager.default.enumerator(
            at: toolDir,
            includingPropertiesForKeys: [.contentModificationDateKey,
                                         .isRegularFileKey,
                                         .fileSizeKey],
            options: [.skipsHiddenFiles])
        var best: (path: String, modDate: Date)?
        let cutoff = lastShownChartTime
        while let url = enumerator?.nextObject() as? URL {
            guard let vals = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .isRegularFileKey, .fileSizeKey]),
                  vals.isRegularFile == true,
                  let modDate = vals.contentModificationDate,
                  modDate > cutoff,
                  mediaExts.contains(url.pathExtension.lowercased())
            else { continue }
            // Skip partial-frame manim renders.
            if url.path.contains("/partial_movie_files/") { continue }
            // Skip files that are too small to be a real chart yet.
            // The fs-event fires the instant the inode is created, but
            // plotly's write_html does ``open(); f.write(huge_str);
            // f.close()`` — the watcher can wake up between open and
            // the first big write. Reading at that moment yields a
            // tiny / empty file. Plotly HTML with ``include_plotlyjs
            // =True`` is reliably > 200 KB; a 4 KB threshold gives a
            // wide safety margin. Only skip when we POSITIVELY know
            // the file is too small — if ``vals.fileSize`` is ``nil``
            // (size key not cached), do NOT skip, because nil means
            // "size unknown" and we'd otherwise drop legitimate files.
            if url.pathExtension.lowercased() == "html",
               let size = vals.fileSize,
               size < 4096 {
                let pathStr = url.path
                if !pollingChartPaths.contains(pathStr) {
                    NSLog("[chart-watch] mid-write %@ (size=%d), starting poll",
                          url.lastPathComponent, size)
                    pollingChartPaths.insert(pathStr)
                    DispatchQueue.main.async { [weak self] in
                        self?.pollForChartCompletion(path: pathStr, attempt: 0)
                    }
                }
                continue
            }
            if let (_, prev) = best, prev >= modDate { continue }
            best = (url.path, modDate)
        }
        guard let pick = best else { return }
        DispatchQueue.main.async { [weak self] in
            self?.tryShowChart(path: pick.path, source: "dir-watch")
        }
    }

    /// Called when WKWebView's WebContent process gets killed by
    /// iOS (memory pressure during backgrounding). The view's
    /// rendered DOM is gone; re-load the same path from disk so
    /// the user doesn't see the chart "reset" on app-switch return.
    @objc private func handlePreviewWebContentDied(_ note: Notification) {
        // Only act if the affected WebView is one we care about
        // (outputWebView or a PreviewSheetViewController's own).
        // PreviewSheetViewController handles its own reload via its
        // delegate, so here we just take care of the inline panel.
        guard let affected = note.object as? WKWebView,
              affected === outputWebView else { return }
        guard let path = currentOutputPath,
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return }
        NSLog("[editor] outputWebView WebContent died — reloading %@", path)
        // Re-issue via the normal entry point so all the visibility
        // bookkeeping (isHidden flags, expand button, etc.) stays
        // consistent. ``showImageOutput`` is idempotent — re-loading
        // the same path doesn't fire the iPhone sheet auto-present
        // (the path is already presented; dedup will no-op).
        showImageOutput(path: path)
    }

    /// True if ``path`` lives under ``~/Documents/ToolOutputs/`` —
    /// the canonical directory where matplotlib's ``_show_hook`` /
    /// plotly's patched ``Figure.show`` / manim renders write their
    /// output files. Used to gate the iPhone auto-present sheet so
    /// it ONLY fires for actual script-produced charts, not for the
    /// many other ``showImageOutput`` callers (editor HTML preview,
    /// file-save refresh, asset→index.html dev-server shim, etc.).
    private func isChartOutputPath(_ path: String) -> Bool {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        let toolOutputs = documents.appendingPathComponent("ToolOutputs").path
        let resolved = (path as NSString).standardizingPath
        return resolved.hasPrefix(toolOutputs)
    }

    /// iPhone-only: present (or update in place) a half-sheet modal
    /// showing the chart at ``path``. Called from ``showImageOutput``
    /// on compact width because the inline outputPanel is hidden
    /// there. Dedupes by path so consecutive ``showImageOutput``
    /// calls for the same file (e.g. dir-watch + PTY scanner both
    /// firing) don't dismiss-then-re-present and cause flicker.
    private func presentOrUpdatePreviewSheet(path: String) {
        // Already showing this exact path? Nothing to do.
        if let current = presentedPreviewSheet, current.currentPath == path {
            return
        }
        // Different path while a sheet is up — load the new content
        // in-place so the user keeps the same sheet they were viewing.
        if let current = presentedPreviewSheet {
            current.load(path: path)
            return
        }
        // No sheet up — create + present.
        let vc = PreviewSheetViewController(path: path)
        if let sheet = vc.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
            sheet.largestUndimmedDetentIdentifier = .medium
        }
        present(vc, animated: true)
        presentedPreviewSheet = vc
    }

    /// Single entry point — both the PTY scanner and the dir watcher
    /// route through here so we don't re-load the same chart twice
    /// when both signals fire.
    private func tryShowChart(path: String, source: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if path == lastShownChartPath {
            // Already showing this exact file — ignore duplicate.
            return
        }
        lastShownChartPath = path
        lastShownChartTime = Date()
        NSLog("[chart-watch] (%@) loading %@", source, path)
        showImageOutput(path: path)
    }

    /// Poll a partially-written chart file until it's complete (size
    /// ≥ 4 KB) or the budget expires, then load it via tryShowChart.
    /// Necessary because the dir-watch fs-event only fires on inode
    /// create — not on subsequent writes into an existing inode —
    /// so a file that's still being written when the watcher first
    /// sees it has no follow-up signal that says "now I'm done".
    /// Budget: 120 s total at 0.5 s intervals. Heavy plotly HTML
    /// (huge surface plots) can take a full minute to serialize on
    /// iOS Python.
    private func pollForChartCompletion(path: String, attempt: Int) {
        let maxAttempts = 240   // 120 s @ 0.5 s
        guard attempt < maxAttempts else {
            NSLog("[chart-watch] poll gave up on %@ after %d attempts",
                  (path as NSString).lastPathComponent, attempt)
            pollingChartPaths.remove(path)
            return
        }
        // File may have been deleted (run cleanup) — stop polling.
        guard FileManager.default.fileExists(atPath: path) else {
            pollingChartPaths.remove(path)
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? 0
        if size >= 4096 {
            NSLog("[chart-watch] poll completed %@ (size=%d, attempts=%d)",
                  (path as NSString).lastPathComponent, size, attempt)
            pollingChartPaths.remove(path)
            tryShowChart(path: path, source: "dir-poll")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pollForChartCompletion(path: path, attempt: attempt + 1)
        }
    }

    private func appendToTerminalFiltered(_ text: String, isError: Bool) {
        // Fast path: if the chunk contains nothing that looks like a
        // tagged debug line, just forward it straight through.
        let prefixes = Self._terminalNoisePrefixes
        if !prefixes.contains(where: { text.contains($0) }) {
            appendToTerminal(text, isError: isError)
            return
        }
        // Mixed or all-noisy chunk — split per-line, route each.
        // Preserve the chunk's trailing newline by tracking it
        // explicitly (otherwise the terminal collapses two prints
        // onto one line).
        let endsWithNewline = text.hasSuffix("\n")
        let lines = text.split(separator: "\n",
                               omittingEmptySubsequences: false)
            .map(String.init)
        var keep: [String] = []
        for line in lines {
            if prefixes.contains(where: { line.hasPrefix($0) }) {
                NSLog("[py] %@", line)
            } else {
                keep.append(line)
            }
        }
        if keep.isEmpty { return }
        var out = keep.joined(separator: "\n")
        if endsWithNewline && !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty {
            appendToTerminal(out, isError: isError)
        }
    }

    @discardableResult
    private func addChatBubble(text: String, isUser: Bool) -> UILabel {
        if isUser {
            // ── User message: right-aligned pill (ChatGPT style) ──
            let label = UILabel()
            label.text = text
            label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            label.textColor = .white
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.translatesAutoresizingMaskIntoConstraints = false

            let bubble = UIView()
            bubble.backgroundColor = UIColor(red: 0.25, green: 0.25, blue: 0.30, alpha: 1) // dark pill
            bubble.layer.cornerRadius = 14
            bubble.translatesAutoresizingMaskIntoConstraints = false
            bubble.addSubview(label)

            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
                label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
                label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8)
            ])

            let wrapper = UIView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(bubble)
            NSLayoutConstraint.activate([
                bubble.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 4),
                bubble.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                bubble.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -4),
                bubble.widthAnchor.constraint(lessThanOrEqualTo: wrapper.widthAnchor, multiplier: 0.85)
            ])

            chatStackView.addArrangedSubview(wrapper)
            scrollChatToBottom()
            return label
        } else {
            // ── AI message: full-width, no bubble background (ChatGPT style) ──
            let label = UILabel()
            label.text = text
            label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            label.textColor = UIColor(white: 0.85, alpha: 1)
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.translatesAutoresizingMaskIntoConstraints = false

            let wrapper = UIView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 6),
                label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -4),
                label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -6)
            ])

            chatStackView.addArrangedSubview(wrapper)
            scrollChatToBottom()
            return label
        }
    }

    /// Render AI response text with basic markdown: **bold**, `code`, ```code blocks```
    private func renderMarkdownText(_ text: String, into label: UILabel) {
        let result = NSMutableAttributedString()
        let normalFont = UIFont.systemFont(ofSize: 13, weight: .regular)
        let boldFont = UIFont.systemFont(ofSize: 13, weight: .bold)
        let codeFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let textColor = UIColor(white: 0.85, alpha: 1)
        let codeColor = UIColor(red: 0.55, green: 0.85, blue: 0.65, alpha: 1)

        // Split by code blocks first
        let codeBlockPattern = "```(?:\\w+)?\\n([\\s\\S]*?)```"
        let inlineCodePattern = "`([^`]+)`"
        let boldPattern = "\\*\\*([^*]+)\\*\\*"

        let remaining = text

        // Simple pass: replace code blocks → inline code → bold
        // Code blocks
        if let regex = try? NSRegularExpression(pattern: codeBlockPattern) {
            let nsRange = NSRange(remaining.startIndex..., in: remaining)
            let matches = regex.matches(in: remaining, range: nsRange)
            var lastEnd = remaining.startIndex
            let temp = NSMutableAttributedString()
            for match in matches {
                let beforeRange = lastEnd..<(Range(match.range, in: remaining)?.lowerBound ?? remaining.endIndex)
                temp.append(NSAttributedString(string: String(remaining[beforeRange]), attributes: [.font: normalFont, .foregroundColor: textColor]))
                if let codeRange = Range(match.range(at: 1), in: remaining) {
                    let codeStr = String(remaining[codeRange])
                    temp.append(NSAttributedString(string: "\n", attributes: [.font: normalFont, .foregroundColor: textColor]))
                    temp.append(NSAttributedString(string: codeStr, attributes: [.font: codeFont, .foregroundColor: codeColor, .backgroundColor: UIColor(white: 0.12, alpha: 1)]))
                    temp.append(NSAttributedString(string: "\n", attributes: [.font: normalFont, .foregroundColor: textColor]))
                }
                lastEnd = Range(match.range, in: remaining)?.upperBound ?? remaining.endIndex
            }
            temp.append(NSAttributedString(string: String(remaining[lastEnd...]), attributes: [.font: normalFont, .foregroundColor: textColor]))
            result.append(temp)
        } else {
            result.append(NSAttributedString(string: remaining, attributes: [.font: normalFont, .foregroundColor: textColor]))
        }

        // Inline code
        if let regex = try? NSRegularExpression(pattern: inlineCodePattern) {
            let matches = regex.matches(in: result.string, range: NSRange(location: 0, length: result.length))
            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result.string) {
                    let code = String(result.string[codeRange])
                    let replacement = NSAttributedString(string: code, attributes: [.font: codeFont, .foregroundColor: codeColor, .backgroundColor: UIColor(white: 0.15, alpha: 1)])
                    result.replaceCharacters(in: match.range, with: replacement)
                }
            }
        }

        // Bold
        if let regex = try? NSRegularExpression(pattern: boldPattern) {
            let matches = regex.matches(in: result.string, range: NSRange(location: 0, length: result.length))
            for match in matches.reversed() {
                if let boldRange = Range(match.range(at: 1), in: result.string) {
                    let boldText = String(result.string[boldRange])
                    let replacement = NSAttributedString(string: boldText, attributes: [.font: boldFont, .foregroundColor: textColor])
                    result.replaceCharacters(in: match.range, with: replacement)
                }
            }
        }

        label.attributedText = result
    }

    private func scrollChatToBottom() {
        chatScrollView.layoutIfNeeded()
        let bottomOffset = CGPoint(x: 0, y: max(0, chatScrollView.contentSize.height - chatScrollView.bounds.height))
        chatScrollView.setContentOffset(bottomOffset, animated: true)
    }

    // MARK: - Line Numbers

    private func updateLineNumbers() {
        let text = codeTextView.text ?? ""
        let lineCount = max(1, text.components(separatedBy: "\n").count)
        lineNumberLabel.text = (1...lineCount).map { String($0) }.joined(separator: "\n")

        // Sync gutter scroll offset
        let yOffset = codeTextView.contentOffset.y
        lineNumberLabel.transform = CGAffineTransform(translationX: 0, y: -yOffset + 8)
    }

    // MARK: - Syntax Highlighting

    private func applySyntaxHighlighting() {
        guard let text = codeTextView.text, !text.isEmpty else { return }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let attributed = NSMutableAttributedString(string: text)

        // Base style
        attributed.addAttributes([
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: EditorTheme.foreground
        ], range: fullRange)

        let keywords: Set<String>
        let commentPrefix: String
        let hasPreprocessor: Bool

        switch currentLanguage {
        case .python:
            keywords = Self.pythonKeywords
            commentPrefix = "#"
            hasPreprocessor = false
        case .c:
            keywords = Self.cKeywords
            commentPrefix = "//"
            hasPreprocessor = true
        case .cpp:
            keywords = Self.cppKeywords
            commentPrefix = "//"
            hasPreprocessor = true
        case .fortran:
            keywords = Self.fortranKeywords
            commentPrefix = "!"
            hasPreprocessor = false
        case .swift:
            keywords = Self.swiftKeywords
            commentPrefix = "//"
            hasPreprocessor = false
        case .latex:
            // We don't run the legacy in-house highlighter for LaTeX —
            // Monaco's tokenizer is much better — so just supply
            // empty/safe values to keep the switch exhaustive.
            keywords = []
            commentPrefix = "%"
            hasPreprocessor = false
        }

        _ = text as NSString  // kept for parity with older code paths; NSRange ops below use Swift ranges

        // 1. Comments (line-based)
        let commentPattern = "\(NSRegularExpression.escapedPattern(for: commentPrefix)).*"
        if let regex = try? NSRegularExpression(pattern: commentPattern, options: []) {
            for match in regex.matches(in: text, options: [], range: fullRange) {
                attributed.addAttribute(.foregroundColor, value: EditorTheme.comment, range: match.range)
            }
        }

        // 2. Strings (double and single quoted)
        if let regex = try? NSRegularExpression(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'", options: []) {
            for match in regex.matches(in: text, options: [], range: fullRange) {
                attributed.addAttribute(.foregroundColor, value: EditorTheme.string, range: match.range)
            }
        }

        // 3. Numbers
        if let regex = try? NSRegularExpression(pattern: "\\b\\d+\\.?\\d*\\b", options: []) {
            for match in regex.matches(in: text, options: [], range: fullRange) {
                attributed.addAttribute(.foregroundColor, value: EditorTheme.number, range: match.range)
            }
        }

        // 4. Keywords
        for keyword in keywords {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                for match in regex.matches(in: text, options: [], range: fullRange) {
                    attributed.addAttribute(.foregroundColor, value: EditorTheme.keyword, range: match.range)
                }
            }
        }

        // 5. Preprocessor directives (#include, #define) for C
        if hasPreprocessor {
            if let regex = try? NSRegularExpression(pattern: "#\\w+", options: []) {
                for match in regex.matches(in: text, options: [], range: fullRange) {
                    attributed.addAttribute(.foregroundColor, value: EditorTheme.keyword, range: match.range)
                }
            }
        }

        // Preserve selection
        let selectedRange = codeTextView.selectedRange
        codeTextView.attributedText = attributed
        codeTextView.selectedRange = selectedRange
    }

    // MARK: - Templates

    @objc private func templatesTapped() {
        let vc = TemplatePickerViewController()
        vc.templates = Self.templates
        vc.onSelect = { [weak self] template in
            guard let self else { return }
            self.currentLanguage = template.language
            self.languageControl.selectedSegmentIndex = template.language.rawValue
            // Dedent the template code (remove leading 8-space indent from multiline strings)
            let lines = template.code.split(separator: "\n", omittingEmptySubsequences: false)
            let dedented = lines.map { line in
                var s = String(line)
                if s.hasPrefix("        ") { s = String(s.dropFirst(8)) }
                return s
            }.joined(separator: "\n")
            self.codeTextView.text = dedented
            self.applySyntaxHighlighting()
            self.updateLineNumbers()
        }
        vc.modalPresentationStyle = .popover
        vc.preferredContentSize = CGSize(width: 400, height: 500)
        if let popover = vc.popoverPresentationController {
            popover.sourceView = templatesButton
            popover.sourceRect = templatesButton.bounds
            popover.permittedArrowDirections = .up
        }
        present(vc, animated: true)
    }

    // MARK: - Docs Viewer

    private func buildDocsMenu() {
        let docFiles: [(String, String, String)] = [
            ("NumPy", "numpy", "fx"),
            ("SciPy", "scipy-ios", "waveform.path.ecg"),
            ("scikit-learn", "sklearn", "brain"),
            ("matplotlib", "matplotlib", "chart.bar"),
            ("SymPy", "sympy", "x.squareroot"),
            ("Manim", "manim", "film"),
            ("Plotly", "plotly", "chart.pie"),
            ("NetworkX", "networkx", "point.3.connected.trianglepath.dotted"),
            ("Pillow (PIL)", "pillow", "photo"),
            ("PyAV + FFmpeg", "av-pyav", "video"),
            ("Cairo + Pango", "libs/media", "paintbrush"),
            ("C Interpreter", "c-interpreter", "chevron.left.forwardslash.chevron.right"),
            ("C++ Interpreter", "cpp-interpreter", "chevron.left.forwardslash.chevron.right"),
            ("Fortran Interpreter", "fortran-interpreter", "chevron.left.forwardslash.chevron.right"),
            ("BeautifulSoup", "beautifulsoup", "globe"),
            ("Requests", "minor-libs", "network"),
            ("mpmath", "mpmath", "number"),
            ("Rich", "rich", "text.alignleft"),
            ("tqdm", "tqdm", "gauge.with.dots.needle.33percent"),
            ("PyYAML", "pyyaml", "doc.text"),
            ("Pygments", "pygments", "paintpalette"),
            ("jsonschema", "jsonschema", "doc.badge.gearshape"),
        ]

        let actions = docFiles.map { (title, file, icon) in
            UIAction(title: title, image: UIImage(systemName: icon)) { [weak self] _ in
                self?.showDocFile(named: file, title: title)
            }
        }

        let menu = UIMenu(title: "Library Documentation", children: actions)
        docsButton.menu = menu
        docsButton.showsMenuAsPrimaryAction = true
    }

    private func showDocFile(named name: String, title: String) {
        // Try to find the markdown file in the app bundle's docs/ directory
        let paths = [
            Bundle.main.path(forResource: name, ofType: "md", inDirectory: "docs"),
            Bundle.main.path(forResource: name, ofType: "md", inDirectory: "docs/libs"),
            Bundle.main.path(forResource: name, ofType: "md"),
        ]
        guard let path = paths.compactMap({ $0 }).first,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            appendToTerminal("$ Doc not found: \(name).md\n", isError: true)
            return
        }

        let vc = UIViewController()
        vc.title = title

        let textView = UITextView()
        textView.isEditable = false
        textView.backgroundColor = EditorTheme.chatBg
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.translatesAutoresizingMaskIntoConstraints = false

        // Simple markdown rendering
        let rendered = renderDocMarkdown(content)
        textView.attributedText = rendered

        vc.view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: vc.view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
        ])

        vc.modalPresentationStyle = .popover
        vc.preferredContentSize = CGSize(width: 500, height: 600)
        if let popover = vc.popoverPresentationController {
            popover.sourceView = docsButton
            popover.sourceRect = docsButton.bounds
            popover.permittedArrowDirections = .up
            popover.backgroundColor = EditorTheme.chatBg
        }
        present(vc, animated: true)
    }

    private func renderDocMarkdown(_ md: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = UIFont.systemFont(ofSize: 14)
        let h1Font = UIFont.systemFont(ofSize: 22, weight: .bold)
        let h2Font = UIFont.systemFont(ofSize: 18, weight: .bold)
        let h3Font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        let codeFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let textColor = UIColor(white: 0.85, alpha: 1)
        let headColor = UIColor.white
        let codeColor = UIColor(red: 0.55, green: 0.85, blue: 0.65, alpha: 1)
        let codeBg = UIColor(white: 0.10, alpha: 1)
        let dimColor = UIColor(white: 0.50, alpha: 1)

        var inCodeBlock = false
        var codeBlockLines: [String] = []

        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCodeBlock {
                    // End code block
                    let code = codeBlockLines.joined(separator: "\n")
                    result.append(NSAttributedString(string: code + "\n\n", attributes: [.font: codeFont, .foregroundColor: codeColor, .backgroundColor: codeBg]))
                    codeBlockLines = []
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }
            if inCodeBlock {
                codeBlockLines.append(line)
                continue
            }

            if line.hasPrefix("### ") {
                let text = String(line.dropFirst(4))
                result.append(NSAttributedString(string: text + "\n", attributes: [.font: h3Font, .foregroundColor: headColor]))
            } else if line.hasPrefix("## ") {
                let text = String(line.dropFirst(3))
                result.append(NSAttributedString(string: "\n" + text + "\n", attributes: [.font: h2Font, .foregroundColor: headColor]))
            } else if line.hasPrefix("# ") {
                let text = String(line.dropFirst(2))
                result.append(NSAttributedString(string: text + "\n", attributes: [.font: h1Font, .foregroundColor: headColor]))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let text = "  • " + String(line.dropFirst(2))
                result.append(NSAttributedString(string: text + "\n", attributes: [.font: bodyFont, .foregroundColor: textColor]))
            } else if line.hasPrefix("|") {
                // Table row — render as-is in monospace
                result.append(NSAttributedString(string: line + "\n", attributes: [.font: codeFont, .foregroundColor: dimColor]))
            } else {
                result.append(NSAttributedString(string: line + "\n", attributes: [.font: bodyFont, .foregroundColor: textColor]))
            }
        }
        return result
    }

    // MARK: - Model Selector

    private func buildModelMenu() -> UIMenu {
        let actions = ModelSlot.allCases.map { slot in
            UIAction(title: slot.title, subtitle: slot.subtitle) { [weak self] _ in
                self?.onModelSelected?(slot)
            }
        }
        return UIMenu(title: "Select Model", children: actions)
    }

    func updateModelName(_ name: String) {
        var config = modelSelectorButton.configuration ?? UIButton.Configuration.tinted()
        config.title = name
        modelSelectorButton.configuration = config
    }

    // MARK: - File Loading

    private var currentFileURL: URL?
    private var currentOutputPath: String?
    /// Floating "expand to fullscreen" button overlaid on the preview
    /// pane. Hidden until an artefact is loaded.
    private let outputExpandButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        b.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right",
                           withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.backgroundColor = UIColor(white: 0, alpha: 0.55)
        b.layer.cornerRadius = 14
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isHidden = true
        return b
    }()
    /// Debounced auto-save: Monaco fires `onTextChanged` every ~150 ms while
    /// the user types, but hitting disk on every keystroke thrashes iCloud
    /// sync and makes battery sad. Coalesce to one write per ~600 ms of
    /// idle, and also flush synchronously on viewWillDisappear / runTapped.
    private var autoSaveTimer: DispatchSourceTimer?
    private var pendingSaveText: String?
    /// Track the loaded-from-disk content so we can skip writes when the
    /// buffer hasn't actually changed (e.g. Monaco firing textChanged
    /// right after our own setCode).
    private var lastSavedText: String?

    func loadFile(url: URL) {
        // Session-restore hook: remember the last opened file so the
        // next app launch can reopen it automatically.
        SessionRestore.lastOpenFile = url
        SessionRestore.lastWorkspace = url.deletingLastPathComponent()
        // Try UTF-8 first, then Latin-1 (which maps every byte 0x00-0xFF),
        // then a lossy fallback from raw bytes. LaTeX .log files commonly
        // have Latin-1 bytes (font names, math glyph debug output) that
        // make UTF-8 decoding fail silently, so the old guard returned
        // without showing anything — the user saw "nothing happens".
        let contents: String
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            contents = s
        } else if let s = try? String(contentsOf: url, encoding: .isoLatin1) {
            contents = s
        } else if let data = try? Data(contentsOf: url) {
            contents = String(decoding: data, as: UTF8.self)  // lossy UTF-8
        } else {
            appendToTerminal("$ Cannot read \(url.lastPathComponent)\n", isError: true)
            return
        }
        // Before switching files, pull Monaco's very latest text and
        // flush it to the OLD file synchronously-enough that we don't
        // race the new file's setCode. `flushAutoSave()` alone isn't
        // enough: Monaco has its own ~150 ms textChanged debounce, so
        // a user who types then quickly taps another file can arrive
        // here with `pendingSaveText == nil` even though Monaco still
        // holds unsaved keystrokes. Capture the OLD url + do getText,
        // and write to that captured url even after we swap Monaco's
        // content — the closure holds the right reference.
        if let oldURL = currentFileURL {
            let priorLastSaved = lastSavedText
            monacoView.getText { [oldURL, priorLastSaved] text in
                if text != priorLastSaved {
                    try? text.write(to: oldURL, atomically: true, encoding: .utf8)
                }
            }
        }
        autoSaveTimer?.cancel()
        autoSaveTimer = nil
        pendingSaveText = nil
        // Auto-detect language from file extension. For formats Monaco
        // doesn't tokenize (log, txt, tex, md, json, yaml, ...), we still
        // pass a language string so Monaco applies the right renderer
        // — this bypasses our 4-value Language enum.
        let ext = url.pathExtension.lowercased()
        let monacoLang: String
        switch ext {
        case "py":
            currentLanguage = .python
            monacoLang = "python"
        case "c", "h":
            currentLanguage = .c
            monacoLang = "c"
        case "cpp", "cc", "cxx", "hpp":
            currentLanguage = .cpp
            monacoLang = "cpp"
        case "f90", "f95", "f", "for":
            currentLanguage = .fortran
            monacoLang = "fortran"
        case "swift":
            currentLanguage = .swift
            monacoLang = "swift"
        case "log", "txt", "out", "err":
            currentLanguage = .python      // closest enum fallback
            monacoLang = "plaintext"        // Monaco built-in, no highlighting
        case "tex", "ltx":
            // .tex / .ltx → Run button compiles via busytex pdftex.
            currentLanguage = .latex
            monacoLang = "latex"
        case "sty", "cls", "def":
            // Style/class/def files aren't standalone documents; treat
            // them as plain text-with-LaTeX-syntax — Run won't help so
            // fall back to Python so it's a no-op rather than failing.
            currentLanguage = .python
            monacoLang = "latex"
        case "md", "markdown":
            currentLanguage = .python
            monacoLang = "markdown"
        case "json":
            currentLanguage = .python
            monacoLang = "json"
        case "yaml", "yml":
            currentLanguage = .python
            monacoLang = "yaml"
        case "html", "htm":
            currentLanguage = .python
            monacoLang = "html"
        case "css":
            currentLanguage = .python
            monacoLang = "css"
        case "js", "mjs", "cjs":
            currentLanguage = .python
            monacoLang = "javascript"
        case "ts", "tsx":
            currentLanguage = .python
            monacoLang = "typescript"
        case "sh", "bash", "zsh":
            currentLanguage = .python
            monacoLang = "shell"
        default:
            currentLanguage = .python
            monacoLang = "python"
        }
        codeTextView.text = contents  // mirror
        monacoView.setCode(contents, language: monacoLang)
        currentFileURL = url
        lastSavedText = contents
        editorFileNameLabel.text = url.lastPathComponent
        applyLanguageTabStyle()
        modifiedDot.isHidden = true
        updateBreadcrumb()
        updateEditorStatusBar()
        // Persist this as the "last opened file" so the next launch
        // restores it (loadInitialFile in viewDidLoad reads this key).
        UserDefaults.standard.set(url.path, forKey: "editor.lastFilePath")
        // File load is reflected in the editor header label; no
        // reason to echo it into the terminal (it's noise during
        // every file-tab click).
        publishCurrentEditorFile(url)
        // Live HTML preview: if the user opens an .html / .htm file,
        // mirror it into the preview pane so they can edit + see the
        // rendered result side-by-side. The preview re-renders on every
        // save (see flushAutoSave). For non-HTML files we leave the
        // preview alone — it might be showing the last script run's
        // output, which the user probably still wants visible.
        //
        // Workspace dev-server convention: if the user opens a CSS / JS
        // / asset file that lives next to an `index.html`, surface the
        // index.html in the preview pane. Editing the asset will then
        // trigger a refresh via flushAutoSave's same-dir asset rule —
        // matches the behaviour of a real dev server.
        if ext == "html" || ext == "htm" {
            showImageOutput(path: url.path)
        } else {
            let webAssetExts: Set<String> = ["css", "js", "mjs", "json", "svg"]
            if webAssetExts.contains(ext) {
                let dir = url.deletingLastPathComponent()
                let candidate = dir.appendingPathComponent("index.html")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    showImageOutput(path: candidate.path)
                }
            }
        }
    }

    func insertCode(_ code: String, language: String) {
        flushAutoSave()
        switch language.lowercased() {
        case "c": currentLanguage = .c
        case "cpp", "c++": currentLanguage = .cpp
        case "fortran", "f90": currentLanguage = .fortran
        case "swift": currentLanguage = .swift
        default: currentLanguage = .python
        }
        codeTextView.text = code  // mirror
        monacoView.setCode(code, language: currentLanguage.monacoName)
        currentFileURL = nil
        lastSavedText = nil
        applyLanguageTabStyle()
        modifiedDot.isHidden = true
        updateBreadcrumb()
        publishCurrentEditorFile(nil)
    }

    /// Expose the currently-open file path to the Python shell via a
    /// shared signal file. The `ai` builtin reads this when invoked
    /// with no arg so the default edit target is whatever file the
    /// user has in the editor right now. Writes an empty file (not
    /// deleted) when nothing's loaded, so the Python side can reliably
    /// distinguish "no current file" from "signal file missing".
    private func publishCurrentEditorFile(_ url: URL?) {
        let dir = NSTemporaryDirectory().appending("latex_signals")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/current_editor_file.txt"
        let content = (url?.path ?? "") + "\n"
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Called from Monaco's textChanged bridge on every keystroke. We
    /// schedule a disk write for ~200 ms later, cancelling any previously
    /// pending timer so only the most recent text hits disk. The old
    /// 600 ms debounce produced a visible "unsaved window" — if the user
    /// switched files or ran a script within it, their latest edit never
    /// made it to disk and subsequent re-reads picked up stale content.
    func scheduleAutoSave(text: String) {
        guard currentFileURL != nil else { return }
        // Settings toggle gate — when the user disables Auto-save in
        // the Settings tab, keystrokes are still tracked
        // (`pendingSaveText`) but the debounced disk write is
        // skipped. Manual saves (⌘S, Run, file-switch) still go
        // through `flushAutoSave` directly so an explicit save
        // works regardless.
        pendingSaveText = text
        guard Settings.autoSaveEnabled else {
            autoSaveTimer?.cancel()
            autoSaveTimer = nil
            return
        }
        autoSaveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.flushAutoSave() }
        timer.resume()
        autoSaveTimer = timer
    }

    /// Fetch Monaco's current in-memory text and flush it to disk NOW,
    /// bypassing both debounce layers. Use this at file-switch / run /
    /// background time when we can't afford to miss the latest edit —
    /// Monaco's own ~150 ms textChanged debounce means `pendingSaveText`
    /// may be nil while the editor still holds unsaved keystrokes.
    func forceFlushFromMonaco(completion: (() -> Void)? = nil) {
        guard let url = currentFileURL else { completion?(); return }
        monacoView.getText { [weak self] text in
            guard let self else { completion?(); return }
            self.autoSaveTimer?.cancel()
            self.autoSaveTimer = nil
            self.pendingSaveText = nil
            if text != self.lastSavedText {
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    self.lastSavedText = text
                } catch {
                    self.appendToTerminal(
                        "$ Save failed: \(error.localizedDescription)\n",
                        isError: true)
                }
            }
            completion?()
        }
    }

    /// Synchronously write whatever's pending to the current file URL.
    /// Safe to call when nothing is pending (no-op). Called from
    /// scheduleAutoSave's timer, runTapped, viewWillDisappear, and
    /// loadFile/insertCode (before they clobber currentFileURL).
    func flushAutoSave() {
        autoSaveTimer?.cancel()
        autoSaveTimer = nil
        guard let url = currentFileURL,
              let text = pendingSaveText else { return }
        pendingSaveText = nil
        if text == lastSavedText { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastSavedText = text
            // Tell the file browser to refresh immediately. The kqueue
            // watcher would catch this anyway via .write, but it
            // debounces by 120ms; a direct notification skips the wait
            // so the side tab updates the moment the save lands.
            NotificationCenter.default.post(
                name: .editorDidSaveFile, object: url)
            // Live web preview: refresh the preview pane if the user
            // just edited:
            //   • the HTML file currently being previewed, OR
            //   • a CSS / JS / asset file in the SAME directory as the
            //     previewed HTML (so editing style.css with index.html
            //     in the preview triggers a reload — that's how a real
            //     dev-server feels).
            // Skip otherwise so saving a .py file doesn't clobber a
            // previously-rendered chart in the preview.
            let ext = url.pathExtension.lowercased()
            let assetExts: Set<String> = [
                "css", "js", "mjs", "json", "svg",
                "png", "jpg", "jpeg", "gif", "webp", "ico",
                "woff", "woff2", "ttf", "otf", "wasm",
            ]
            if let preview = currentOutputPath {
                let isHTMLPreview = preview.hasSuffix(".html") || preview.hasSuffix(".htm")
                let savedDir = url.deletingLastPathComponent().standardized.path
                let previewDir = (preview as NSString).deletingLastPathComponent
                let inSameDir = (savedDir == previewDir)
                let isAsset = assetExts.contains(ext)
                if isHTMLPreview && (preview == url.path || (inSameDir && isAsset)) {
                    showImageOutput(path: preview)
                }
            }
        } catch {
            appendToTerminal("$ Save failed: \(error.localizedDescription)\n",
                             isError: true)
        }
    }

    func saveCurrentFile() {
        guard let url = currentFileURL else { return }
        monacoView.getText { [weak self] text in
            guard let self else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self.lastSavedText = text
                self.pendingSaveText = nil
                // Silent save — no terminal output. Save failures still
                // surface below so the user isn't left thinking their
                // work persisted when it didn't.
            } catch {
                self.appendToTerminal("$ Save failed: \(error.localizedDescription)\n", isError: true)
            }
        }
    }

    // MARK: - Image Output

    @objc private func exportOutput() {
        guard let path = currentOutputPath, FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        let ac = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        ac.popoverPresentationController?.sourceView = view
        ac.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: 50, width: 0, height: 0)
        present(ac, animated: true)
    }

    private func showImageOutput(path: String?) {
        // Hide everything first
        outputImageView.isHidden = true
        outputImageView.image = nil
        outputWebView.isHidden = true
        outputWebView.stopLoading()
        // The blank-HTML preload that used to sit here was meant to
        // drop the previous DOM so a manim ``_video_player.html``
        // wouldn't keep playing through the hidden transition. But
        // when the NEW content is also HTML (e.g. a plotly chart
        // from ``python foo.py``), loading blank-then-real produces
        // back-to-back async loads — the blank gets cancelled with
        // ``NSURLErrorCancelled (-999)`` and the chart load
        // intermittently inherits the cancelled state, leaving the
        // preview blank. So we only blank-preload when the next
        // content is NOT html; for html→html, ``stopLoading`` plus
        // the upcoming ``loadHTMLString`` is enough — the chart's
        // DOM replaces the previous one atomically.
        let nextIsHTML = (path?.lowercased().hasSuffix(".html") ?? false)
        if !nextIsHTML {
            outputWebView.loadHTMLString(
                "<!doctype html><body style='background:#0a0a0f;margin:0'></body>",
                baseURL: nil)
        }
        outputPDFView.isHidden = true
        outputPDFView.document = nil
        setOutputEmptyStateHidden(false)
        outputExpandButton.isHidden = true
        currentOutputPath = path

        guard let path = path, !path.isEmpty else {
            appendToTerminal("$ [output] No image path\n", isError: false)
            return
        }

        // iPhone (compact width): surface the chart as a half-sheet
        // because the inline outputPanel is hidden. BUT only auto-
        // present for actual chart renders — not for the many other
        // ``showImageOutput`` callers (HTML file open, file-save
        // refresh, asset → index.html dev-server shim, restored
        // ``currentOutputPath`` on launch, etc.). Otherwise the
        // sheet pops up uninvited every time the user just opens
        // an HTML file in the editor and they have to dismiss it.
        //
        // Chart files written by sitecustomize.py / PythonRuntime
        // .swift's _show_hook variants land in ToolOutputs/. User
        // HTML lives elsewhere in the workspace. The path-prefix
        // check separates the two cleanly.
        if isCompactWidth, isChartOutputPath(path) {
            presentOrUpdatePreviewSheet(path: path)
        }

        // pywebview shim can send http(s):// URLs straight through.
        // Those go to the WKWebView as a real network request so the
        // page gets the correct origin (cookies, referer, CSP, JS
        // controls all behave the way they would in a normal browser
        // — wrapping them in a file:// meta-refresh used to silently
        // break things like form submits and OAuth flows).
        if path.hasPrefix("http://") || path.hasPrefix("https://"),
           let urlForLoad = URL(string: path) {
            appendToTerminal("$ [output] loading URL \(path)\n", isError: false)
            setOutputEmptyStateHidden(true)
            outputWebView.isHidden = false
            outputExpandButton.isHidden = false
            // Bind the pywebview JS↔Python bridge to this WebView so
            // evaluate_js / js_api round-trips work against the live
            // page. Idempotent — safe to call on every load.
            PywebviewBridge.shared.bind(outputWebView)
            outputWebView.load(URLRequest(url: urlForLoad))
            return
        }

        let exists = FileManager.default.fileExists(atPath: path)
        appendToTerminal("$ [output] \(URL(fileURLWithPath: path).lastPathComponent) exists=\(exists)\n", isError: false)
        guard exists else { return }
        outputExpandButton.isHidden = false

        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        if ext == "html" {
            setOutputEmptyStateHidden(true)
            outputWebView.isHidden = false
            // Bind the pywebview bridge so evaluate_js / js_api work
            // against this page too (load_html signal lands here).
            PywebviewBridge.shared.bind(outputWebView)
            // Prefer in-memory load via loadHTMLString. On macOS
            // Catalyst / Designed-for-iPad, loadFileURL(allowingReadAccessTo:)
            // intermittently fails because the WebContent process's
            // sandbox access grant races with the actual load —
            // logged as "WebProcessProxy::hasAssumedReadAccessToURL:
            // no access" and the chart never renders. Reading the
            // HTML into memory and passing baseURL for relative-URL
            // resolution sidesteps the sandbox check entirely.
            // For huge HTML (>20 MB), fall back to loadFileURL to
            // avoid copying into a Swift String unnecessarily.
            let parentDir = url.deletingLastPathComponent()
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            if fileSize > 0 && fileSize < 20 * 1024 * 1024,
               let html = try? String(contentsOf: url, encoding: .utf8) {
                outputWebView.loadHTMLString(html, baseURL: parentDir)
            } else {
                outputWebView.loadFileURL(url, allowingReadAccessTo: parentDir)
            }
        } else if ext == "pdf" {
            // PDFKit's PDFView — native multi-page continuous scroll,
            // pinch-zoom, text-select. WKWebView's embedded PDF
            // rendering ignored our scrollView settings because the
            // injected viewport CSS (`overflow:hidden !important`)
            // clamped it to one page.
            setOutputEmptyStateHidden(true)
            outputPDFView.isHidden = false
            if let doc = PDFDocument(url: url) {
                outputPDFView.document = doc
                outputPDFView.goToFirstPage(nil)
            } else {
                appendToTerminal("$ [output] failed to open PDF\n", isError: true)
            }
        } else if ext == "gif" {
            // Animated GIF (manim) — display in WKWebView for animation support
            setOutputEmptyStateHidden(true)
            outputWebView.isHidden = false
            let gifHTML = """
            <!DOCTYPE html>
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>body{margin:0;background:#000;display:flex;align-items:center;justify-content:center;height:100vh}
            img{max-width:100%;max-height:100%;border-radius:8px;image-rendering:auto}</style></head>
            <body><img src="\(url.lastPathComponent)"></body></html>
            """
            let htmlURL = url.deletingLastPathComponent().appendingPathComponent("_gif_viewer.html")
            try? gifHTML.write(to: htmlURL, atomically: true, encoding: .utf8)
            outputWebView.loadFileURL(htmlURL, allowingReadAccessTo: url.deletingLastPathComponent())
        } else if ["mp4", "mov", "webm", "m4v"].contains(ext) {
            // Video output — play in WKWebView with HTML5 video
            setOutputEmptyStateHidden(true)
            outputWebView.isHidden = false
            let videoHTML = """
            <!DOCTYPE html>
            <html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
            *{margin:0;padding:0;box-sizing:border-box;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent}
            body{background:#1e1e2e;display:flex;flex-direction:column;height:100vh;font-family:-apple-system,system-ui,sans-serif;overflow:hidden}
            .player{flex:1;display:flex;align-items:center;justify-content:center;position:relative;overflow:hidden;background:#000}
            video{max-width:100%;max-height:100%;background:#000}
            .controls{display:flex;align-items:center;gap:4px;padding:8px 10px;background:rgba(30,30,46,0.98);border-top:1px solid rgba(255,255,255,0.08)}
            .btn{background:none;border:none;color:#cdd6f4;cursor:pointer;padding:8px;border-radius:8px;display:flex;align-items:center;justify-content:center;min-width:36px;min-height:36px;transition:background 0.15s, transform 0.08s}
            .btn:hover{background:rgba(255,255,255,0.08)}
            .btn:active{background:rgba(255,255,255,0.18);transform:scale(0.92)}
            .btn.flash{background:#a6e3a1 !important;color:#1e1e2e}
            .btn svg{width:20px;height:20px;fill:currentColor;pointer-events:none}
            .progress-wrap{flex:1;min-width:60px;height:32px;display:flex;align-items:center;cursor:pointer;position:relative;padding:0 4px}
            .progress{width:100%;height:4px;background:#45475a;border-radius:2px;position:relative}
            .progress-fill{height:100%;background:#89b4fa;border-radius:2px;width:0%;pointer-events:none;transition:width 0.08s linear}
            .progress-thumb{position:absolute;top:50%;width:14px;height:14px;background:#89b4fa;border-radius:50%;transform:translate(-50%,-50%);pointer-events:none;left:0;box-shadow:0 0 0 3px rgba(137,180,250,0.25);transition:left 0.08s linear}
            .time{color:#a6adc8;font-size:12px;min-width:38px;text-align:center;font-variant-numeric:tabular-nums}
            .speed{color:#cdd6f4;font-size:12px;font-weight:600;cursor:pointer;padding:6px 10px;border:1px solid rgba(255,255,255,0.14);border-radius:8px;background:rgba(255,255,255,0.06);min-width:42px;text-align:center}
            .speed:active{background:rgba(255,255,255,0.16);transform:scale(0.94)}
            .btn.active{color:#89b4fa;background:rgba(137,180,250,0.15)}
            .toast{position:absolute;bottom:60px;left:50%;transform:translateX(-50%);background:rgba(166,227,161,0.95);color:#1e1e2e;padding:10px 18px;border-radius:10px;font-size:14px;font-weight:600;opacity:0;transition:opacity 0.25s;pointer-events:none;box-shadow:0 4px 12px rgba(0,0,0,0.3)}
            .toast.show{opacity:1}
            .toast.err{background:rgba(243,139,168,0.95)}
            </style></head>
            <body>
            <div class="player">
              <video id="v" playsinline preload="auto" muted></video>
              <div id="toast" class="toast"></div>
            </div>
            <div class="controls">
              <button class="btn" id="playBtn" title="Play/Pause"><svg viewBox="0 0 24 24"><path id="playIcon" d="M8,5 L19,12 L8,19Z"/></svg></button>
              <span class="time" id="curTime">0:00</span>
              <div class="progress-wrap" id="progWrap"><div class="progress"><div class="progress-fill" id="progFill"></div><div class="progress-thumb" id="progThumb"></div></div></div>
              <span class="time" id="durTime">0:00</span>
              <span class="speed" id="speedBtn">1×</span>
              <button class="btn active" id="loopBtn" title="Loop"><svg viewBox="0 0 24 24"><path d="M7,7h10l-1.6-1.6L16.8,4l3.6,3.6-3.6,3.6-1.4-1.4L17,8H7v3H5V7h2zm10,10H7l1.6,1.6L7.2,20l-3.6-3.6L7.2,13l1.4,1.4L7,16h10v-3h2v5h-2z"/></svg></button>
              <button class="btn" id="shareBtn" title="Share / Save to Files"><svg viewBox="0 0 24 24"><path d="M12,2 L8,6 L9.4,7.4 L11,5.8 L11,15 L13,15 L13,5.8 L14.6,7.4 L16,6 L12,2 Z M5,18 L5,20 L19,20 L19,18 L5,18 Z"/></svg></button>
              <button class="btn" id="saveBtn" title="Save to Photos"><svg viewBox="0 0 24 24"><path d="M19,3 H5 C3.9,3 3,3.9 3,5 V19 C3,20.1 3.9,21 5,21 H19 C20.1,21 21,20.1 21,19 V5 C21,3.9 20.1,3 19,3 Z M19,19 H5 V5 H19 V19 Z M13.96,12.29 L11.21,15.83 L9.25,13.47 L6.5,17 H17.5 L13.96,12.29 Z"/></svg></button>
            </div>
            <script>
            const v=document.getElementById('v'),pb=document.getElementById('playBtn'),pi=document.getElementById('playIcon'),
                  pf=document.getElementById('progFill'),pt=document.getElementById('progThumb'),pw=document.getElementById('progWrap'),
                  ct=document.getElementById('curTime'),dt=document.getElementById('durTime'),
                  sb=document.getElementById('speedBtn'),lb=document.getElementById('loopBtn'),
                  shareBtn=document.getElementById('shareBtn'),saveBtn=document.getElementById('saveBtn'),
                  toast=document.getElementById('toast');
            const source=document.createElement('source');
            source.src='\(url.lastPathComponent)';source.type='video/mp4';v.appendChild(source);
            let speeds=[0.5,1,1.5,2],si=1;
            const playD='M8,5 L19,12 L8,19Z',pauseD='M7,5 L10,5 L10,19 L7,19Z M14,5 L17,5 L17,19 L14,19Z';
            v.loop=true;v.muted=true;

            function showToast(msg,err){toast.textContent=msg;toast.classList.remove('err');if(err)toast.classList.add('err');toast.classList.add('show');setTimeout(()=>toast.classList.remove('show'),2200)}
            function flashBtn(b){b.classList.add('flash');setTimeout(()=>b.classList.remove('flash'),300)}
            function fmt(s){if(!s||!isFinite(s))return '0:00';const m=Math.floor(s/60),sec=Math.floor(s%60);return m+':'+(sec<10?'0':'')+sec}

            v.addEventListener('loadeddata',()=>{v.play().catch(()=>{});pi.setAttribute('d',pauseD);dt.textContent=fmt(v.duration)});
            v.addEventListener('timeupdate',()=>{if(v.duration){const p=v.currentTime/v.duration*100;pf.style.width=p+'%';pt.style.left=p+'%';ct.textContent=fmt(v.currentTime)}});
            v.addEventListener('play',()=>pi.setAttribute('d',pauseD));
            v.addEventListener('pause',()=>pi.setAttribute('d',playD));
            v.addEventListener('error',e=>showToast('Video failed to load',true));

            // Single source of truth for tap events — Safari on iOS sometimes
            // swallows click events on nested SVG paths; using pointerdown on
            // the button is reliable.
            function bindTap(el,fn){el.addEventListener('pointerdown',e=>{e.preventDefault();fn()})}
            bindTap(pb,()=>v.paused?v.play():v.pause());
            bindTap(sb,()=>{si=(si+1)%speeds.length;v.playbackRate=speeds[si];sb.textContent=speeds[si]+'×'});
            bindTap(lb,()=>{v.loop=!v.loop;lb.classList.toggle('active',v.loop);showToast(v.loop?'Loop on':'Loop off')});
            bindTap(shareBtn,()=>{
                try{webkit.messageHandlers.shareVideo.postMessage('share');flashBtn(shareBtn);showToast('Opening share…')}
                catch(e){showToast('Share unavailable',true)}
            });
            bindTap(saveBtn,()=>{
                try{webkit.messageHandlers.saveVideo.postMessage('save');flashBtn(saveBtn);showToast('Saving to Photos…')}
                catch(e){showToast('Save unavailable',true)}
            });
            // Progress bar scrub — pointer events for iOS touch reliability
            let dragging=false;
            function seekFromEvent(e){if(!v.duration)return;const r=pw.getBoundingClientRect();const x=Math.max(0,Math.min(r.width,(e.clientX||e.touches?.[0]?.clientX||0)-r.left));v.currentTime=x/r.width*v.duration}
            pw.addEventListener('pointerdown',e=>{dragging=true;seekFromEvent(e);pw.setPointerCapture(e.pointerId)});
            pw.addEventListener('pointermove',e=>{if(dragging)seekFromEvent(e)});
            pw.addEventListener('pointerup',e=>{dragging=false});
            </script>
            </body></html>
            """
            let htmlURL = url.deletingLastPathComponent().appendingPathComponent("_video_player.html")
            try? videoHTML.write(to: htmlURL, atomically: true, encoding: .utf8)
            outputWebView.loadFileURL(htmlURL, allowingReadAccessTo: url.deletingLastPathComponent())
        } else if ["png", "jpg", "jpeg"].contains(ext) {
            if let image = UIImage(contentsOfFile: path) {
                setOutputEmptyStateHidden(true)
                outputImageView.image = image
                outputImageView.isHidden = false
            }
        }
    }
}

// MARK: - UITextViewDelegate

// MARK: - Suggestions Table DataSource/Delegate

extension CodeEditorViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return currentSuggestions.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "suggestion") ?? UITableViewCell(style: .value1, reuseIdentifier: "suggestion")
        guard indexPath.row < currentSuggestions.count else { return cell }
        let item = currentSuggestions[indexPath.row]

        // Kind-based icon + color
        let iconCfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        cell.imageView?.image = UIImage(systemName: item.kind.sfSymbol, withConfiguration: iconCfg)
        cell.imageView?.tintColor = item.kind.tintColor

        // Bold the matched prefix (e.g. "ar" in "array")
        cell.textLabel?.attributedText = highlightedLabel(item.label, prefix: currentMatchPrefix)
        cell.textLabel?.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        cell.textLabel?.textColor = UIColor(white: 0.90, alpha: 1)

        // Right-side detail (module name / type info)
        cell.detailTextLabel?.text = item.detail
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 10, weight: .regular)
        cell.detailTextLabel?.textColor = UIColor(white: 0.50, alpha: 1)

        cell.backgroundColor = .clear
        let selectedView = UIView()
        selectedView.backgroundColor = UIColor(red: 0.20, green: 0.30, blue: 0.50, alpha: 0.4)
        cell.selectedBackgroundView = selectedView
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.row < currentSuggestions.count else { return }
        applySuggestion(currentSuggestions[indexPath.row])
        tableView.deselectRow(at: indexPath, animated: true)
    }

    /// Highlighting a row (e.g. via arrow keys) triggers the doc preview fetch.
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Focus the first row by default — shows docs for the top suggestion
        if indexPath.row == 0 && !docPreviewVisible {
            let item = currentSuggestions[indexPath.row]
            fetchDocsAndShow(for: item)
        }
    }

    /// Fetch docs from the Python daemon and show them in the preview panel.
    private func fetchDocsAndShow(for item: CompletionItem) {
        guard item.module != nil else {
            hideDocPreview()
            return
        }
        // Show panel immediately with "Loading..."
        docPreviewSignatureLabel.text = "\(item.label)(...)"
        docPreviewTextView.text = "Loading..."
        showDocPreviewPanel()

        IntelliSenseEngine.shared.resolve(item) { [weak self] resolved in
            guard let self else { return }
            // Only update if this is still the focused item (user may have moved)
            guard self.currentSuggestions.first(where: { $0.label == resolved.label && $0.module == resolved.module }) != nil else { return }
            let sig = resolved.signature ?? ""
            self.docPreviewSignatureLabel.text = sig.isEmpty ? resolved.label : "\(resolved.label)\(sig)"
            self.docPreviewTextView.text = resolved.documentation?.isEmpty == false
                ? resolved.documentation
                : "No documentation available."
        }
    }

    private func showDocPreviewPanel() {
        // Position to the right of suggestionsTable
        for c in view.constraints where (c.firstItem === docPreviewPanel || c.secondItem === docPreviewPanel) {
            if c.firstAttribute == .leading || c.firstAttribute == .top {
                c.isActive = false
            }
        }
        NSLayoutConstraint.activate([
            docPreviewPanel.topAnchor.constraint(equalTo: suggestionsTable.topAnchor),
            docPreviewPanel.leadingAnchor.constraint(equalTo: suggestionsTable.trailingAnchor, constant: 6),
        ])
        docPreviewPanel.isHidden = false
        docPreviewVisible = true
        view.bringSubviewToFront(docPreviewPanel)
    }

    private func hideDocPreview() {
        docPreviewPanel.isHidden = true
        docPreviewVisible = false
    }

    /// Produces an NSAttributedString with the matched prefix bolded.
    private func highlightedLabel(_ label: String, prefix: String) -> NSAttributedString {
        let baseFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let attr = NSMutableAttributedString(string: label, attributes: [.font: baseFont])
        if !prefix.isEmpty, label.lowercased().hasPrefix(prefix.lowercased()) {
            let range = NSRange(location: 0, length: prefix.count)
            attr.addAttributes([
                .font: boldFont,
                .foregroundColor: UIColor(red: 0.55, green: 0.80, blue: 0.95, alpha: 1),
            ], range: range)
        }
        return attr
    }
}

extension CodeEditorViewController: UITextViewDelegate {

    func textViewDidChange(_ textView: UITextView) {
        applySyntaxHighlighting()
        updateLineNumbers()
        if textView === codeTextView {
            scheduleSuggestionUpdate()
        }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        if textView === codeTextView && !suggestionsHidden {
            scheduleSuggestionUpdate()
        }
    }

    /// Debounced wrapper around `updateSuggestions()`.
    /// Cancels any pending update and schedules a new one 180ms out.
    /// This keeps the UI thread free during rapid typing.
    private func scheduleSuggestionUpdate() {
        suggestionDebouncer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.updateSuggestions()
        }
        suggestionDebouncer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180), execute: work)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === codeTextView {
            updateLineNumbers()
        }
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard textView === codeTextView else { return true }

        // Signature help trigger: `(` after an identifier
        if text == "(" {
            // Let the text change go through first, then query after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
                self?.handleSignatureHelpTrigger()
            }
        }
        // Closing `)` dismisses the signature tooltip
        if text == ")" {
            hideSignatureTooltip()
        }

        // Tab key inserts 4 spaces
        if text == "\t" {
            let spaces = "    "
            let nsText = (textView.text as NSString).replacingCharacters(in: range, with: spaces)
            textView.text = nsText
            textView.selectedRange = NSRange(location: range.location + 4, length: 0)
            applySyntaxHighlighting()
            updateLineNumbers()
            return false
        }

        // Auto-indent after colon or opening brace
        if text == "\n" {
            let nsText = textView.text as NSString
            let lineRange = nsText.lineRange(for: NSRange(location: range.location, length: 0))
            let currentLine = nsText.substring(with: lineRange)

            // Compute current indentation
            var indent = ""
            for ch in currentLine {
                if ch == " " { indent += " " }
                else { break }
            }

            let trimmed = currentLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix(":") || trimmed.hasSuffix("{") {
                indent += "    "
            }

            let replacement = "\n\(indent)"
            let newText = nsText.replacingCharacters(in: range, with: replacement)
            textView.text = newText
            textView.selectedRange = NSRange(location: range.location + replacement.count, length: 0)
            applySyntaxHighlighting()
            updateLineNumbers()
            return false
        }

        return true
    }
}

// MARK: - UITextFieldDelegate

extension CodeEditorViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === chatInputField {
            sendChatMessage()
        } else if textField === terminalInputField {
            terminalInputSubmitted()
        }
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        if textField === terminalInputField && !terminalShellReady {
            // First time the terminal input gains focus, make sure the
            // shell module is loaded and update the prompt label.
            terminalShellReady = true
            refreshTerminalPrompt()
        }
    }
}

// MARK: - TerminalInputField — UITextField that routes ↑/↓ through a callback

final class TerminalInputField: UITextField {
    var onHistoryUp:   (() -> Void)?
    var onHistoryDown: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow,   modifierFlags: [], action: #selector(_histUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(_histDown)),
        ]
    }

    @objc private func _histUp()   { onHistoryUp?() }
    @objc private func _histDown() { onHistoryDown?() }
}

// MARK: - MinimalTerminalAccessory — compact 4-key toolbar for soft keyboard sessions.
//
// Shown ONLY when no magic keyboard is connected. SwiftTerm's default
// accessory had ESC, Tab, Ctrl, Up/Down/Left/Right, F1…F12 — useless
// on a device that has a hardware keyboard, and too busy on phones.
// This is a 4-button row: ESC, Tab, Ctrl, dismiss-keyboard.
final class MinimalTerminalAccessory: UIInputView {

    private let send: ([UInt8]) -> Void

    init(send: @escaping ([UInt8]) -> Void) {
        self.send = send
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 40),
                   inputViewStyle: .keyboard)
        allowsSelfSizing = true
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        translatesAutoresizingMaskIntoConstraints = false
        // Keys iOS soft keyboard doesn't provide or hides in number/symbol pages:
        // esc, tab, ctrl-C / ctrl-D (handy in a REPL), ←/→, ⌫ (explicit delete
        // button in case Return eats the backspace on certain layouts).
        let esc   = makeButton("esc") { [weak self] in self?.send([0x1b]) }
        let tab   = makeButton("tab") { [weak self] in self?.send([0x09]) }
        let ctrlC = makeButton("⌃C")  { [weak self] in self?.send([0x03]) }
        let ctrlD = makeButton("⌃D")  { [weak self] in self?.send([0x04]) }
        let left  = makeButton("←", mono: true) { [weak self] in self?.send([0x1b, 0x5b, 0x44]) }
        let right = makeButton("→", mono: true) { [weak self] in self?.send([0x1b, 0x5b, 0x43]) }
        let up    = makeButton("↑", mono: true) { [weak self] in self?.send([0x1b, 0x5b, 0x41]) }
        let dn    = makeButton("↓", mono: true) { [weak self] in self?.send([0x1b, 0x5b, 0x42]) }
        let back  = makeButton("⌫", mono: true) { [weak self] in self?.send([0x7f]) }
        let dismiss = makeButton("⌄") { [weak self] in self?.resignAncestorResponder() }

        let stack = UIStackView(arrangedSubviews: [
            esc, tab, ctrlC, ctrlD, left, right, up, dn, back, UIView(), dismiss,
        ])
        stack.axis = .horizontal
        stack.spacing = 4
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    private func makeButton(_ title: String, mono: Bool = false, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        var cfg = UIButton.Configuration.gray()
        cfg.title = title
        cfg.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: mono
                ? UIFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
                : UIFont.systemFont(ofSize: 13, weight: .semibold),
        ]))
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        b.configuration = cfg
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    // Walk up the responder chain to resign whatever has focus (the terminal view).
    private func resignAncestorResponder() {
        var r: UIResponder? = self
        while r != nil {
            if let tr = r as? UITextInput, let v = tr as? UIView, v.isFirstResponder {
                v.resignFirstResponder()
                return
            }
            r = r?.next
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - UIPopoverPresentationControllerDelegate

extension CodeEditorViewController: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        return .none
    }
}

// MARK: - UIDocumentPickerDelegate — for the toolbar "Open" button.

extension CodeEditorViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        // The picker was created with `asCopy: true`, so the URL points
        // at a copy in the app's sandbox — we own it and don't need
        // startAccessingSecurityScopedResource. Just hand it to
        // loadFile, which is the same code path the file browser tap
        // uses (syntax highlighting, autocomplete, recent-file list).
        loadFile(url: url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // No-op — user dismissed the picker without choosing a file.
    }
}

// MARK: - FilesBrowserDelegate — the embedded file panel forwards
// file taps and model-load requests up to the editor host.

extension CodeEditorViewController: FilesBrowserDelegate {
    func filesBrowser(_ controller: FilesBrowserViewController, didSelectCodeFile url: URL) {
        // Same routing the sidebar-mounted version used to do:
        // tapping a code file loads it into Monaco + flips
        // currentFileURL / lastSavedText accordingly.
        loadFile(url: url)
    }

    func filesBrowser(_ controller: FilesBrowserViewController, didRequestLoadModel url: URL) {
        // Surface a terminal note. The model-management UI lives in
        // GameViewController; the editor itself just acknowledges the
        // tap. A future refinement could post a notification picked up
        // by ModelsManagerViewController.
        appendToTerminal("$ Model load requested: \(url.lastPathComponent) — open Models tab to mount.\n",
                         isError: false)
    }
}

// MARK: - UIGestureRecognizerDelegate — let SwiftTerm's long-press
// selection gestures coexist with our tap-to-focus gesture.

extension CodeEditorViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Allow our tap-to-focus on SwiftTerm to coexist with its own
        // long-press / pan gestures that drive text selection.
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        // If the user starts a long-press / pan (selection), let that
        // win over our focus tap. No focus-change until the gesture ends.
        if other is UILongPressGestureRecognizer || other is UIPanGestureRecognizer {
            return true
        }
        return false
    }
}

// MARK: - UIPointerInteractionDelegate — show I-beam cursor over terminal
//
// On Mac Catalyst / iPad Pro with trackpad, the default UIPointer is the
// arrow. For a text-selectable view like the terminal, users expect an
// I-beam so the region *looks* selectable. SwiftTerm doesn't install
// this interaction itself.

@available(iOS 13.4, macCatalyst 13.4, *)
extension CodeEditorViewController: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction,
                            styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // The editor↔output resize handle: show a horizontal beam so
        // the cursor visually signals "drag me sideways".
        if interaction.view === outputDragHandle {
            return UIPointerStyle(shape: .horizontalBeam(length: 24))
        }
        // Text-editable region — I-beam. Everything else falls through
        // to the default system pointer.
        return UIPointerStyle(shape: .verticalBeam(length: 20))
    }
}

// MARK: - Terminal double-click-to-select-word
//
// Double-tap inside SwiftTerm selects the word under the cursor. A
// lightweight stub here — SwiftTerm doesn't expose a public "select
// word at point" API, but tapping the cursor twice puts focus there
// and then we don't interfere with SwiftTerm's own single-click logic.
// Users who need precise word-select can drag; this just catches the
// muscle-memory double-click that Mac users will try.

extension CodeEditorViewController {
    @objc fileprivate func terminalDoubleTapSelect(_ g: UITapGestureRecognizer) {
        // Focus on double-tap — SwiftTerm's own internal logic handles
        // the actual text selection if the user follows up with a drag.
        focusTerminal()
    }
}

// MARK: - WKScriptMessageHandler (Video Save)

extension CodeEditorViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "saveVideo":
            saveVideoToPhotos()
        case "shareVideo":
            shareCurrentOutput()
        case "clipboard":
            // Page asked to copy text via the navigator.clipboard /
            // execCommand polyfill. message.body is the string to copy.
            let text: String
            if let s = message.body as? String {
                text = s
            } else if let dict = message.body as? [String: Any],
                      let s = dict["text"] as? String {
                text = s
            } else {
                text = String(describing: message.body)
            }
            UIPasteboard.general.string = text
            // Brief feedback in the terminal so the user sees it worked
            // even though there's no visual change in the preview pane.
            let preview = text.prefix(40).replacingOccurrences(of: "\n", with: " ")
            let suffix = text.count > 40 ? "…" : ""
            appendToTerminal("$ [clipboard] copied \(text.count) char(s): \"\(preview)\(suffix)\"\n",
                              isError: false)
        default:
            break
        }
    }

    private func shareCurrentOutput() {
        guard let path = currentOutputPath, FileManager.default.fileExists(atPath: path) else {
            appendToTerminal("$ No file to share\n", isError: true)
            return
        }
        let url = URL(fileURLWithPath: path)
        let ac = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        ac.popoverPresentationController?.sourceView = outputPanel
        ac.popoverPresentationController?.sourceRect = CGRect(
            x: outputPanel.bounds.midX, y: outputPanel.bounds.maxY - 40, width: 0, height: 0
        )
        present(ac, animated: true)
    }

    private func saveVideoToPhotos() {
        guard let path = currentOutputPath, FileManager.default.fileExists(atPath: path) else {
            appendToTerminal("$ No video to save\n", isError: true)
            return
        }

        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        if ["mp4", "mov", "m4v"].contains(ext) {
            // Save video to Photos
            UISaveVideoAtPathToSavedPhotosAlbum(path, self, #selector(videoSaveCompleted(_:didFinishSavingWithError:contextInfo:)), nil)
        } else {
            // For non-video files, use share sheet
            let ac = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            ac.popoverPresentationController?.sourceView = outputPanel
            ac.popoverPresentationController?.sourceRect = CGRect(x: outputPanel.bounds.midX, y: outputPanel.bounds.maxY - 40, width: 0, height: 0)
            present(ac, animated: true)
        }
    }

    @objc private func videoSaveCompleted(_ videoPath: String, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer?) {
        DispatchQueue.main.async { [weak self] in
            if let error = error {
                self?.appendToTerminal("$ Save failed: \(error.localizedDescription)\n", isError: true)
            } else {
                self?.appendToTerminal("$ Video saved to Photos\n", isError: false)
                // Brief visual feedback
                let label = UILabel()
                label.text = "Saved to Photos"
                label.font = .systemFont(ofSize: 14, weight: .semibold)
                label.textColor = .white
                label.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.85)
                label.textAlignment = .center
                label.layer.cornerRadius = 8
                label.clipsToBounds = true
                label.translatesAutoresizingMaskIntoConstraints = false
                self?.outputPanel.addSubview(label)
                if let panel = self?.outputPanel {
                    NSLayoutConstraint.activate([
                        label.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
                        label.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -50),
                        label.widthAnchor.constraint(equalToConstant: 160),
                        label.heightAnchor.constraint(equalToConstant: 32),
                    ])
                }
                UIView.animate(withDuration: 0.3, delay: 1.5, options: .curveEaseOut) {
                    label.alpha = 0
                } completion: { _ in
                    label.removeFromSuperview()
                }
            }
        }
    }
}

// MARK: - Template Picker

/// Popover/modal that lists templates grouped by category.
final class TemplatePickerViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {

    var templates: [CodeEditorViewController.Template] = []
    var onSelect: ((CodeEditorViewController.Template) -> Void)?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var grouped: [(category: String, items: [CodeEditorViewController.Template])] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        buildGrouped()
        setupTable()
    }

    private func buildGrouped() {
        var dict: [String: [CodeEditorViewController.Template]] = [:]
        var order: [String] = []
        for t in templates {
            if dict[t.category] == nil { order.append(t.category) }
            dict[t.category, default: []].append(t)
        }
        grouped = order.map { (category: $0, items: dict[$0]!) }
    }

    private func setupTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        let titleLabel = UILabel()
        titleLabel.text = "Templates"
        titleLabel.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            tableView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int { grouped.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { grouped[section].category }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { grouped[section].items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let item = grouped[indexPath.section].items[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = item.title
        config.secondaryText = item.language.title
        config.image = UIImage(systemName: item.icon)
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = grouped[indexPath.section].items[indexPath.row]
        dismiss(animated: true) { [weak self] in
            self?.onSelect?(item)
        }
    }
}


/// UITapGestureRecognizer subclass whose `state` and
/// `location(in:)` always return whatever was forced into them.
/// Used as a fake parameter when forwarding to SwiftTerm
/// `doubleTap:` from a long-press recognizer (SwiftTerm bails
/// early unless state == .ended).
private final class ForcedEndedTapRecognizer: UITapGestureRecognizer {
    weak var attached: UIView?
    var fakeLocation: CGPoint = .zero
    override var state: UIGestureRecognizer.State {
        get { .ended }
        set { /* ignored */ }
    }
    override var view: UIView? { attached }
    override func location(in view: UIView?) -> CGPoint { fakeLocation }
}


/// UIPanGestureRecognizer subclass whose `state` and
/// `location(in:)` / `translation(in:)` return whatever was forced
/// into them. Used as the parameter when forwarding finger-drag
/// to SwiftTerm's @objc panSelectionHandler — that handler
/// switches on state, so we need to hit .began (sets pivot),
/// .changed (extends), and .ended (closes + shows menu).
private final class ForcedStatePanRecognizer: UIPanGestureRecognizer {
    weak var attached: UIView?
    var fakeLocation: CGPoint = .zero
    var fakeTranslation: CGPoint = .zero
    var fakeState: UIGestureRecognizer.State = .changed
    override var state: UIGestureRecognizer.State {
        get { fakeState }
        set { /* ignored */ }
    }
    override var view: UIView? { attached }
    override func location(in view: UIView?) -> CGPoint { fakeLocation }
    override func translation(in view: UIView?) -> CGPoint { fakeTranslation }
    // panSelectionHandler calls setTranslation(.zero, in: self) — must be a no-op
    override func setTranslation(_ translation: CGPoint, in view: UIView?) { }
}


// ---------------------------------------------------------------------------
// PreviewSheetViewController — half-sheet wrapper for showing charts /
// HTML / images on iPhone (compact width). The inline ``outputPanel``
// in ``CodeEditorViewController`` is hidden on compact because it
// would consume the whole screen; instead, ``showImageOutput`` calls
// ``presentOrUpdatePreviewSheet`` which puts the same content into
// this sheet. User dismisses with swipe-down or the close button.
// ---------------------------------------------------------------------------

fileprivate final class PreviewSheetViewController: UIViewController, WKNavigationDelegate {
    private(set) var currentPath: String
    private let webView = WKWebView()
    private let closeButton = UIButton(type: .system)
    private let pathLabel = UILabel()

    init(path: String) {
        self.currentPath = path
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }
    required init?(coder: NSCoder) {
        fatalError("PreviewSheetViewController only used programmatically")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0x0a/255.0,
                                       green: 0x0a/255.0,
                                       blue: 0x0f/255.0, alpha: 1)

        // Title row — shows the filename + a close button so users
        // who don't know to swipe-down to dismiss have a clear way out.
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = UIColor(white: 0.65, alpha: 1)
        pathLabel.lineBreakMode = .byTruncatingMiddle

        var closeCfg = UIButton.Configuration.plain()
        closeCfg.image = UIImage(systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        closeCfg.baseForegroundColor = UIColor(white: 0.55, alpha: 1)
        closeCfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 12)
        closeButton.configuration = closeCfg
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.backgroundColor = view.backgroundColor
        webView.isOpaque = false
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        // Own our navigation delegate so we can recover from
        // WebContent process death — iOS routinely kills the
        // WebContent process when the app is backgrounded for a
        // while. Without this, the sheet shows a blank page when
        // the user returns from app-switch.
        webView.navigationDelegate = self

        view.addSubview(pathLabel)
        view.addSubview(closeButton)
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            pathLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
            pathLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            webView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 4),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        load(path: currentPath)
    }

    /// Reload the sheet's WebView with a new chart file. Called by
    /// ``CodeEditorViewController.presentOrUpdatePreviewSheet`` when
    /// a new chart arrives while the sheet is already presented.
    /// Falls back to a visible diagnostic HTML page if the file is
    /// missing / empty / unreadable — previously the WebView's dark
    /// background just showed through making the sheet look "broken
    /// — only a black thing".
    func load(path: String) {
        currentPath = path
        pathLabel.text = (path as NSString).lastPathComponent

        guard FileManager.default.fileExists(atPath: path) else {
            NSLog("[preview-sheet] file does not exist: %@", path)
            webView.loadHTMLString(_diagHTML(
                title: "File not found",
                detail: "The preview file no longer exists:\n\(path)"),
                baseURL: nil)
            return
        }

        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let parentDir = url.deletingLastPathComponent()
        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: path)[.size] as? Int) ?? 0

        // Empty / nearly-empty file — shows what's happening rather
        // than letting the WebView's dark background fool the user
        // into thinking the sheet is broken.
        if fileSize < 64 {
            NSLog("[preview-sheet] file is too small (%d bytes): %@",
                  fileSize, path)
            webView.loadHTMLString(_diagHTML(
                title: "Waiting for content",
                detail: "The file is still being written (\(fileSize) bytes). " +
                        "If the script is still running, this will update " +
                        "once the file is complete. If the script has " +
                        "finished, it may have failed before writing the " +
                        "full output."),
                baseURL: nil)
            return
        }

        if ext == "html" || ext == "htm" {
            // Mirror CodeEditorViewController.showImageOutput — read
            // file content + loadHTMLString so we sidestep WKWebView's
            // ``loadFileURL(allowingReadAccessTo:)`` sandbox race on
            // macOS Catalyst. Fall back to loadFileURL if the file
            // is huge (>20 MB) — String(contentsOf:) would copy the
            // whole thing into memory.
            if fileSize < 20 * 1024 * 1024,
               let html = try? String(contentsOf: url, encoding: .utf8) {
                NSLog("[preview-sheet] loading HTML (%d bytes): %@",
                      fileSize, path)
                webView.loadHTMLString(html, baseURL: parentDir)
            } else {
                NSLog("[preview-sheet] loadFileURL fallback (%d bytes): %@",
                      fileSize, path)
                webView.loadFileURL(url, allowingReadAccessTo: parentDir)
            }
        } else if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) {
            // Wrap image in a centered HTML page for clean display.
            let html = """
            <!DOCTYPE html><html><head>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>html,body{margin:0;background:#0a0a0f;height:100%}
            body{display:flex;align-items:center;justify-content:center}
            img{max-width:100%;max-height:100%;object-fit:contain}</style>
            </head><body><img src="\(url.lastPathComponent)"></body></html>
            """
            webView.loadHTMLString(html, baseURL: parentDir)
        } else if ext == "pdf" {
            webView.loadFileURL(url, allowingReadAccessTo: parentDir)
        } else {
            NSLog("[preview-sheet] unsupported extension: %@", ext)
            webView.loadHTMLString(_diagHTML(
                title: "Unsupported preview format",
                detail: "This sheet shows HTML / PNG / JPG / GIF / WebP / " +
                        "PDF. The file extension '.\(ext)' isn't one of " +
                        "those — open the file from the file browser " +
                        "instead."),
                baseURL: nil)
        }
    }

    /// Diagnostic HTML page used when the requested file can't be
    /// rendered — empty file, missing file, unsupported format.
    /// Light text on the sheet's dark background so the user knows
    /// the sheet is alive (not "stuck on black").
    private func _diagHTML(title: String, detail: String) -> String {
        let safeDetail = detail
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
          html,body{margin:0;background:#0a0a0f;color:#cdd6f4;
            font:14px -apple-system,system-ui,sans-serif;height:100%}
          body{display:flex;flex-direction:column;align-items:center;
            justify-content:center;padding:32px;text-align:center;
            -webkit-user-select:text;user-select:text}
          h1{color:#89b4fa;font-size:18px;font-weight:600;margin:0 0 12px}
          p{color:#a6adc8;line-height:1.5;max-width:340px;
            font-size:13px;margin:0;white-space:pre-wrap;
            font-family:-apple-system,system-ui,sans-serif}
        </style></head>
        <body><h1>\(title)</h1><p>\(safeDetail)</p></body></html>
        """
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    // MARK: - WKNavigationDelegate

    /// WebContent process killed by iOS (memory pressure during
    /// backgrounding). Re-load from disk so the user doesn't see
    /// a blank sheet on app-switch return.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("[preview-sheet] WebContent process terminated — reloading %@",
              currentPath)
        // The file is still on disk in ToolOutputs — re-render same
        // content via the existing load() pipeline (handles HTML
        // images PDF + diagnostic fallback for missing files).
        load(path: currentPath)
    }
}
