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

        var title: String {
            switch self {
            case .python: return "Python"
            case .c: return "C"
            case .cpp: return "C++"
            case .fortran: return "Fortran"
            }
        }

        /// Monaco language identifier.
        var monacoName: String {
            switch self {
            case .python: return "python"
            case .c: return "c"
            case .cpp: return "cpp"
            case .fortran: return "fortran" // Tokenizer is registered by editor.js
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
    private let languageControl = UISegmentedControl(items: ["Python", "C", "C++", "Fortran"])  // hidden, kept for internal state
    private let runButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let openFileButton = UIButton(type: .system)
    private let templatesButton = UIButton(type: .system)  // unused but kept for compile compat
    private let aiToggleButton = UIButton(type: .system)
    private let latexTestButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let docsButton = UIButton(type: .system)

    // Editor
    private let editorContainer = UIView()
    private let editorHeaderBar = UIView()
    private let editorFileNameLabel = UILabel()

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
        l.text = "▶  Run code to see output"
        l.textColor = UIColor(white: 0.30, alpha: 1)
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textAlignment = .center
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

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = EditorTheme.background
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

    // MARK: - Setup Toolbar

    private func setupToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = EditorTheme.background.withAlphaComponent(0.95)

        // Language control is hidden — auto-detected from file extension
        languageControl.selectedSegmentIndex = 0
        languageControl.isHidden = true

        var runConfig = UIButton.Configuration.filled()
        runConfig.image = UIImage(systemName: "play.fill")
        runConfig.title = "Run"
        runConfig.imagePadding = 6
        runConfig.baseBackgroundColor = .systemGreen
        runConfig.baseForegroundColor = .white
        runConfig.cornerStyle = .capsule
        runConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        runButton.configuration = runConfig
        runButton.addTarget(self, action: #selector(runTapped), for: .touchUpInside)
        runButton.translatesAutoresizingMaskIntoConstraints = false

        var clearConfig = UIButton.Configuration.plain()
        clearConfig.image = UIImage(systemName: "trash")
        clearConfig.baseForegroundColor = EditorTheme.foreground
        clearButton.configuration = clearConfig
        clearButton.addTarget(self, action: #selector(clearTerminal), for: .touchUpInside)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        // "Open file" button — surfaces UIDocumentPicker for any source
        // file the user wants to load into the editor. Uses the indigo
        // accent so it reads as a primary action without competing
        // with the green Run button.
        var openConfig = UIButton.Configuration.plain()
        openConfig.image = UIImage(systemName: "folder.badge.plus")
        openConfig.title = "Open"
        openConfig.imagePadding = 4
        openConfig.baseForegroundColor = EditorTheme.accent
        openConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        openFileButton.configuration = openConfig
        openFileButton.addTarget(self, action: #selector(openFileTapped), for: .touchUpInside)
        openFileButton.translatesAutoresizingMaskIntoConstraints = false

        // Templates button removed from toolbar (templates accessible via file explorer)

        // AI Assist button is configured in setupEditor() — nothing to do here.
        // The button lives in the editor header bar (violet-indigo pill).

        var latexConfig = UIButton.Configuration.plain()
        latexConfig.image = UIImage(systemName: "function")
        latexConfig.title = "LaTeX"
        latexConfig.imagePadding = 4
        latexConfig.baseForegroundColor = .systemPink
        latexTestButton.configuration = latexConfig
        latexTestButton.addTarget(self, action: #selector(showLaTeXPreview), for: .touchUpInside)
        latexTestButton.translatesAutoresizingMaskIntoConstraints = false

        var settingsConfig = UIButton.Configuration.plain()
        settingsConfig.image = UIImage(systemName: "gearshape.fill")
        settingsConfig.baseForegroundColor = EditorTheme.foreground
        settingsButton.configuration = settingsConfig
        settingsButton.addTarget(self, action: #selector(toggleSettingsPanel), for: .touchUpInside)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Docs button removed — Docs available via top-level Docs tab
        // AI Assist button moved to editor header (see setupEditor)

        let toolbarStack = UIStackView(arrangedSubviews: [runButton, openFileButton, clearButton, spacer, latexTestButton, settingsButton])
        toolbarStack.axis = .horizontal
        toolbarStack.spacing = 12
        toolbarStack.alignment = .center
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(toolbarStack)
        NSLayoutConstraint.activate([
            toolbarStack.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 8),
            toolbarStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            toolbarStack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            toolbarStack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -8)
        ])
    }

    // MARK: - Setup Editor

    private func setupEditor() {
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.backgroundColor = EditorTheme.background
        editorContainer.layer.cornerRadius = 0
        editorContainer.clipsToBounds = true

        // ── Editor header: VS Code/ManimStudio–style tab bar ──
        editorHeaderBar.translatesAutoresizingMaskIntoConstraints = false
        editorHeaderBar.backgroundColor = EditorTheme.gutterBg
        // bottom border (subtle accent glow)
        let headerBorder = UIView()
        headerBorder.translatesAutoresizingMaskIntoConstraints = false
        headerBorder.backgroundColor = EditorTheme.borderSub
        editorHeaderBar.addSubview(headerBorder)

        // File tab pill: violet code icon + filename
        let fileTabPill = UIView()
        fileTabPill.translatesAutoresizingMaskIntoConstraints = false
        fileTabPill.backgroundColor = EditorTheme.background
        fileTabPill.layer.cornerRadius = 6
        fileTabPill.layer.cornerCurve = .continuous
        fileTabPill.layer.borderColor = EditorTheme.borderSub.cgColor
        fileTabPill.layer.borderWidth = 1

        let fileIconLabel = UILabel()
        fileIconLabel.translatesAutoresizingMaskIntoConstraints = false
        fileIconLabel.text = "</>"
        fileIconLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        fileIconLabel.textColor = EditorTheme.accentViolet

        editorFileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        editorFileNameLabel.text = "main.py"
        editorFileNameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        editorFileNameLabel.textColor = EditorTheme.foreground

        fileTabPill.addSubview(fileIconLabel)
        fileTabPill.addSubview(editorFileNameLabel)

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

        editorHeaderBar.addSubview(fileTabPill)
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
        }

        editorContainer.addSubview(editorHeaderBar)
        editorContainer.addSubview(monacoView)

        NSLayoutConstraint.activate([
            editorHeaderBar.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            editorHeaderBar.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            editorHeaderBar.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            editorHeaderBar.heightAnchor.constraint(equalToConstant: 34),

            headerBorder.bottomAnchor.constraint(equalTo: editorHeaderBar.bottomAnchor),
            headerBorder.leadingAnchor.constraint(equalTo: editorHeaderBar.leadingAnchor),
            headerBorder.trailingAnchor.constraint(equalTo: editorHeaderBar.trailingAnchor),
            headerBorder.heightAnchor.constraint(equalToConstant: 0.5),

            fileTabPill.leadingAnchor.constraint(equalTo: editorHeaderBar.leadingAnchor, constant: 10),
            fileTabPill.centerYAnchor.constraint(equalTo: editorHeaderBar.centerYAnchor),
            fileTabPill.heightAnchor.constraint(equalToConstant: 24),

            fileIconLabel.leadingAnchor.constraint(equalTo: fileTabPill.leadingAnchor, constant: 8),
            fileIconLabel.centerYAnchor.constraint(equalTo: fileTabPill.centerYAnchor),

            editorFileNameLabel.leadingAnchor.constraint(equalTo: fileIconLabel.trailingAnchor, constant: 6),
            editorFileNameLabel.trailingAnchor.constraint(equalTo: fileTabPill.trailingAnchor, constant: -8),
            editorFileNameLabel.centerYAnchor.constraint(equalTo: fileTabPill.centerYAnchor),

            aiToggleButton.trailingAnchor.constraint(equalTo: editorHeaderBar.trailingAnchor, constant: -10),
            aiToggleButton.centerYAnchor.constraint(equalTo: editorHeaderBar.centerYAnchor),
            aiToggleButton.heightAnchor.constraint(equalToConstant: 26),

            monacoView.topAnchor.constraint(equalTo: editorHeaderBar.bottomAnchor),
            monacoView.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            monacoView.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            monacoView.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
        ])
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
        // Left border
        let outBorder = UIView()
        outBorder.backgroundColor = UIColor(white: 0.20, alpha: 0.6)
        outBorder.translatesAutoresizingMaskIntoConstraints = false
        outputPanel.addSubview(outBorder)
        NSLayoutConstraint.activate([
            outBorder.topAnchor.constraint(equalTo: outputPanel.topAnchor),
            outBorder.leadingAnchor.constraint(equalTo: outputPanel.leadingAnchor),
            outBorder.bottomAnchor.constraint(equalTo: outputPanel.bottomAnchor),
            outBorder.widthAnchor.constraint(equalToConstant: 0.5),
        ])

        // Register JS→Swift message handlers for video controls
        outputWebView.configuration.userContentController.add(self, name: "saveVideo")
        outputWebView.configuration.userContentController.add(self, name: "shareVideo")

        outputPanel.addSubview(outputPlaceholderLabel)
        outputPanel.addSubview(outputWebView)
        outputPanel.addSubview(outputImageView)
        outputPanel.addSubview(outputPDFView)
        outputPanel.addSubview(outputExpandButton)

        // Initially hide everything except placeholder
        outputWebView.isHidden = true
        outputImageView.isHidden = true
        outputPDFView.isHidden = true

        outputExpandButton.addTarget(self, action: #selector(presentFullscreenPreview),
                                     for: .touchUpInside)

        NSLayoutConstraint.activate([
            outputWebView.topAnchor.constraint(equalTo: outputPanel.topAnchor),
            outputWebView.leadingAnchor.constraint(equalTo: outputPanel.leadingAnchor),
            outputWebView.trailingAnchor.constraint(equalTo: outputPanel.trailingAnchor),
            outputWebView.bottomAnchor.constraint(equalTo: outputPanel.bottomAnchor),

            outputImageView.topAnchor.constraint(equalTo: outputPanel.topAnchor, constant: 4),
            outputImageView.leadingAnchor.constraint(equalTo: outputPanel.leadingAnchor, constant: 4),
            outputImageView.trailingAnchor.constraint(equalTo: outputPanel.trailingAnchor, constant: -4),
            outputImageView.bottomAnchor.constraint(equalTo: outputPanel.bottomAnchor, constant: -4),

            outputPDFView.topAnchor.constraint(equalTo: outputPanel.topAnchor, constant: 4),
            outputPDFView.leadingAnchor.constraint(equalTo: outputPanel.leadingAnchor, constant: 4),
            outputPDFView.trailingAnchor.constraint(equalTo: outputPanel.trailingAnchor, constant: -4),
            outputPDFView.bottomAnchor.constraint(equalTo: outputPanel.bottomAnchor, constant: -4),

            outputPlaceholderLabel.centerXAnchor.constraint(equalTo: outputPanel.centerXAnchor),
            outputPlaceholderLabel.centerYAnchor.constraint(equalTo: outputPanel.centerYAnchor),

            outputExpandButton.topAnchor.constraint(equalTo: outputPanel.topAnchor, constant: 8),
            outputExpandButton.trailingAnchor.constraint(equalTo: outputPanel.trailingAnchor, constant: -8),
            outputExpandButton.widthAnchor.constraint(equalToConstant: 28),
            outputExpandButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @objc private func presentFullscreenPreview() {
        guard let path = currentOutputPath,
              FileManager.default.fileExists(atPath: path) else { return }
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

        // Title bar — Mac-style with FUNCTIONAL traffic lights + controls
        terminalTitleBar.translatesAutoresizingMaskIntoConstraints = false
        terminalTitleBar.backgroundColor = EditorTheme.gutterBg

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
        makeTrafficLight(terminalTrafficClose, color: UIColor(red: 1.00, green: 0.38, blue: 0.38, alpha: 1), glyph: "xmark")
        makeTrafficLight(terminalTrafficMin,   color: UIColor(red: 1.00, green: 0.75, blue: 0.20, alpha: 1), glyph: "minus")
        makeTrafficLight(terminalTrafficMax,   color: UIColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1), glyph: "arrow.up.left.and.arrow.down.right")
        terminalTrafficClose.addTarget(self, action: #selector(terminalClose),   for: .touchUpInside)
        terminalTrafficMin.addTarget(self,   action: #selector(terminalMinimize), for: .touchUpInside)
        terminalTrafficMax.addTarget(self,   action: #selector(terminalMaximize), for: .touchUpInside)

        let trafficLights = UIStackView(arrangedSubviews: [terminalTrafficClose, terminalTrafficMin, terminalTrafficMax])
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

        // Small SF-Symbols buttons on the right (Ctrl+C, font- / font+, menu, copy, clear)
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
        makeTerminalIconButton(terminalInterruptButton, systemName: "stop.fill",
                               tint: UIColor(red: 1, green: 0.5, blue: 0.5, alpha: 1),
                               action: #selector(terminalInterrupt))
        makeTerminalIconButton(terminalFontMinusButton, systemName: "textformat.size.smaller",
                               action: #selector(terminalFontSmaller))
        makeTerminalIconButton(terminalFontPlusButton,  systemName: "textformat.size.larger",
                               action: #selector(terminalFontLarger))
        makeTerminalIconButton(terminalMenuButton, systemName: "ellipsis.circle",
                               action: #selector(showTerminalMenu(_:)))
        makeTerminalIconButton(terminalCopyButton, systemName: "doc.on.doc",
                               action: #selector(copyTerminalContents))
        makeTerminalIconButton(terminalClearButton, systemName: "trash",
                               action: #selector(clearTerminal))

        // Right-side control stack
        let rightControls = UIStackView(arrangedSubviews: [
            terminalInterruptButton,
            terminalFontMinusButton,
            terminalFontPlusButton,
            terminalMenuButton,
            terminalCopyButton,
            terminalClearButton,
        ])
        rightControls.translatesAutoresizingMaskIntoConstraints = false
        rightControls.axis = .horizontal
        rightControls.spacing = 0
        rightControls.distribution = .equalSpacing

        // Status cluster in the center/left
        let statusCluster = UIStackView(arrangedSubviews: [terminalStatusDot, terminalStatusLabel, terminalSpinner])
        statusCluster.translatesAutoresizingMaskIntoConstraints = false
        statusCluster.axis = .horizontal
        statusCluster.spacing = 5
        statusCluster.alignment = .center

        // Simplified Mac-Terminal look: traffic lights (left), centered
        // title showing the current process/cwd, and a small three-icon
        // toolbar (interrupt, menu, font). The status cluster + full
        // control row from before was too busy — real Terminal.app has
        // none of that visible, just lights + title.
        terminalTitleBar.addSubview(terminalDragHandle)
        terminalTitleBar.addSubview(trafficLights)
        terminalTitleBar.addSubview(terminalTitleLabel)
        terminalTitleBar.addSubview(rightControls)
        // statusCluster still exists for future use (e.g. pip progress),
        // but no longer pinned into the bar. Keep it as a floating view.
        statusCluster.isHidden = true

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
        // Eagerly boot Python + start the REPL thread in the background
        // so that when the user types `ls` + Enter into the terminal
        // BEFORE tapping Run, there's a reader on the other side of
        // the pipe ready to dispatch. Without this, Enter submits the
        // line and nothing happens because no REPL thread exists yet.
        PythonRuntime.shared.ensureRuntimeReady()
        setTerminalInitialBanner()

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

        // Cursor-drag-to-select: SwiftTerm only enables drag-to-select
        // AFTER a long-press triggers selection mode. On Mac Catalyst
        // (trackpad/mouse) we want drag-to-select from the first touch,
        // just like any normal text view. Reach into SwiftTerm's own
        // long-press recognizer and cut its minimumPressDuration to
        // 0.05s — near-zero so a trackpad click-and-drag feels like
        // a native text-selection drag. Stationary tap/release still
        // gets counted as a tap because the recognizer needs *any*
        // movement before transitioning out of .began.
        for gr in swiftTermView.gestureRecognizers ?? [] {
            if let lp = gr as? UILongPressGestureRecognizer,
               lp.minimumPressDuration > 0.3 {
                lp.minimumPressDuration = 0.05
                lp.allowableMovement = 4  // tighten tap slop so drag wins sooner
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
            terminalTitleBar.heightAnchor.constraint(equalToConstant: 32),

            terminalDragHandle.centerXAnchor.constraint(equalTo: terminalTitleBar.centerXAnchor),
            terminalDragHandle.topAnchor.constraint(equalTo: terminalTitleBar.topAnchor, constant: 4),
            terminalDragHandle.widthAnchor.constraint(equalToConstant: 36),
            terminalDragHandle.heightAnchor.constraint(equalToConstant: 3),

            trafficLights.leadingAnchor.constraint(equalTo: terminalTitleBar.leadingAnchor, constant: 12),
            trafficLights.centerYAnchor.constraint(equalTo: terminalTitleBar.centerYAnchor),

            // Fixed-size status dot to keep its aspect when it does get shown
            terminalStatusDot.widthAnchor.constraint(equalToConstant: 8),
            terminalStatusDot.heightAnchor.constraint(equalToConstant: 8),

            // Center title — floats between traffic lights and right-side controls
            terminalTitleLabel.centerXAnchor.constraint(equalTo: terminalTitleBar.centerXAnchor),
            terminalTitleLabel.centerYAnchor.constraint(equalTo: terminalTitleBar.centerYAnchor),
            terminalTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: trafficLights.trailingAnchor, constant: 12),
            terminalTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightControls.leadingAnchor, constant: -12),

            rightControls.trailingAnchor.constraint(equalTo: terminalTitleBar.trailingAnchor, constant: -4),
            rightControls.centerYAnchor.constraint(equalTo: terminalTitleBar.centerYAnchor),
            rightControls.heightAnchor.constraint(equalToConstant: 28),

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
        // A single reassuring line so typing visibly works before Python
        // finishes Py_Initialize (~0.5–1 s on cold launch).
        let boot = "\u{1b}[38;5;244mstarting python… you can start typing\u{1b}[0m\r\n"
        swiftTermView.feed(text: boot)
    }

    private func setTerminalStatus(_ s: TerminalStatus) {
        terminalStatusDot.backgroundColor = s.color
        terminalStatusLabel.text = s.title
        terminalStatusLabel.textColor = s.color
        if s == .running { terminalSpinner.startAnimating() } else { terminalSpinner.stopAnimating() }
    }

    // MARK: - Setup Settings Panel

    private func setupSettingsPanel() {
        // Settings are shown as a popover — nothing to set up here
        // Controls are created fresh each time the popover opens
    }

    @objc private func manimQualityChanged(_ sender: UISegmentedControl) {
        UserDefaults.standard.set(sender.selectedSegmentIndex, forKey: "manim_quality")
    }

    @objc private func manimFPSChanged(_ sender: UISegmentedControl) {
        UserDefaults.standard.set(sender.selectedSegmentIndex, forKey: "manim_fps")
    }

    // MARK: - Layout

    private func setupLayout() {
        // ManimStudio-style layout:
        //   Left panel = code editor + AI chat overlay (inline, right side of editor)
        //   Right = output/preview panel
        //   Bottom = terminal (full width)

        // Left panel: editor fills it, AI chat overlays the right edge
        leftPanel.translatesAutoresizingMaskIntoConstraints = false
        leftPanel.addSubview(editorContainer)
        leftPanel.addSubview(aiChatContainer)

        // AI chat width: ~240pt fixed, overlays the right side of the editor
        // Start collapsed to match `isAIChatVisible = false` — user opens it
        // explicitly via the AI Assist toggle in the editor header.
        aiChatWidthConstraint = aiChatContainer.widthAnchor.constraint(equalToConstant: 0)
        aiChatContainer.alpha = 0

        NSLayoutConstraint.activate([
            // Editor fills the full left panel (behind the chat overlay)
            editorContainer.topAnchor.constraint(equalTo: leftPanel.topAnchor),
            editorContainer.leadingAnchor.constraint(equalTo: leftPanel.leadingAnchor),
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

        // 2-column: editor (with chat overlay) | output/preview
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topStack.axis = .horizontal
        topStack.spacing = 2
        topStack.distribution = .fill
        topStack.addArrangedSubview(leftPanel)
        topStack.addArrangedSubview(outputPanel)

        outputPanelWidthConstraint = outputPanel.widthAnchor.constraint(equalTo: topStack.widthAnchor, multiplier: 0.40)
        outputPanelWidthConstraint.isActive = true

        // Main vertical stack: toolbar + topStack + terminal
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.axis = .vertical
        mainStack.spacing = 2
        mainStack.addArrangedSubview(toolbar)
        mainStack.addArrangedSubview(topStack)
        mainStack.addArrangedSubview(terminalContainer)

        view.addSubview(mainStack)

        // Taller default: title bar (32) + textview + input bar (36). 200 gives
        // ~132 pt of visible scrollback on iPhone which is comfortable.
        terminalHeightConstraint = terminalContainer.heightAnchor.constraint(equalToConstant: 200)
        terminalHeightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: view.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            toolbar.heightAnchor.constraint(equalToConstant: 48),
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
        editorFileNameLabel.text = "</> (untitled)"
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
                self.showImageOutput(path: resultImagePath)

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
        outputPlaceholderLabel.isHidden = false

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
        fpsSeg.selectedSegmentIndex = UserDefaults.standard.integer(forKey: "manim_fps")
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

    // MARK: - Interrupt, font-size, menu

    /// Stop.fill button — sets Py_RaiseSignal(SIGINT) on the Python
    /// interpreter so a long-running script can be broken out of.
    @objc private func terminalInterrupt() {
        let code = """
        import _thread, ctypes, signal, sys
        # Raise KeyboardInterrupt in the main thread (works even if we're
        # mid-exec in a streaming script). If a C extension has the GIL
        # this won't fire until control returns to Python — usually fast.
        try:
            signal.raise_signal(signal.SIGINT)
        except Exception:
            _thread.interrupt_main()
        print('\\n\\x1b[33m^C — interrupted\\x1b[0m')
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = PythonRuntime.shared.execute(code: code) { chunk in
                DispatchQueue.main.async { self?.appendToTerminal(chunk, isError: false) }
            }
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @objc private func terminalFontSmaller() {
        terminalFontSize = max(9, terminalFontSize - 1)
        applyTerminalFontSize()
    }

    @objc private func terminalFontLarger() {
        terminalFontSize = min(22, terminalFontSize + 1)
        applyTerminalFontSize()
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncTerminalSizeToPTY()
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
        // Only register these when the terminal view is first responder —
        // otherwise they'd fire while the user is typing in the code
        // editor's WebView, which has its own Ctrl+C (= copy) semantics.
        guard swiftTermView.isFirstResponder else { return base }
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
        return base + [c, d, z, cmdA, cmdC]
    }

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
    private func appendToTerminal(_ text: String, isError: Bool) {
        // If the caller tagged this as an error, bracket in red so stuff
        // without its own escape codes still stands out.
        let wrapped: String
        if isError && !text.contains("\u{1b}[") {
            wrapped = "\u{1b}[31m" + text + "\u{1b}[0m"
        } else {
            wrapped = text
        }
        swiftTermView.feed(text: wrapped)
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
        case "log", "txt", "out", "err":
            currentLanguage = .python      // closest enum fallback
            monacoLang = "plaintext"        // Monaco built-in, no highlighting
        case "tex", "ltx", "sty", "cls", "def":
            currentLanguage = .python
            monacoLang = "latex"            // Monaco ships a LaTeX tokenizer
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
        editorFileNameLabel.text = "</> \(url.lastPathComponent)"
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
        default: currentLanguage = .python
        }
        codeTextView.text = code  // mirror
        monacoView.setCode(code, language: currentLanguage.monacoName)
        currentFileURL = nil
        lastSavedText = nil
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
        pendingSaveText = text
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
        // Stop any in-flight load and drop the previous DOM. Without
        // this, a manim _video_player.html from the prior run kept
        // playing in the (hidden) WebView and would briefly flash
        // through whenever the WebView was unhidden for the next page
        // — the new content's loadFileURL is async, so the old DOM
        // had time to render before the swap.
        outputWebView.stopLoading()
        outputWebView.loadHTMLString(
            "<!doctype html><body style='background:#0a0a0f;margin:0'></body>",
            baseURL: nil)
        outputPDFView.isHidden = true
        outputPDFView.document = nil
        outputPlaceholderLabel.isHidden = false
        outputExpandButton.isHidden = true
        currentOutputPath = path

        guard let path = path, !path.isEmpty else {
            appendToTerminal("$ [output] No image path\n", isError: false)
            return
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
            outputPlaceholderLabel.isHidden = true
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
            outputPlaceholderLabel.isHidden = true
            outputWebView.isHidden = false
            // Bind the pywebview bridge so evaluate_js / js_api work
            // against this page too (load_html signal lands here).
            PywebviewBridge.shared.bind(outputWebView)
            outputWebView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else if ext == "pdf" {
            // PDFKit's PDFView — native multi-page continuous scroll,
            // pinch-zoom, text-select. WKWebView's embedded PDF
            // rendering ignored our scrollView settings because the
            // injected viewport CSS (`overflow:hidden !important`)
            // clamped it to one page.
            outputPlaceholderLabel.isHidden = true
            outputPDFView.isHidden = false
            if let doc = PDFDocument(url: url) {
                outputPDFView.document = doc
                outputPDFView.goToFirstPage(nil)
            } else {
                appendToTerminal("$ [output] failed to open PDF\n", isError: true)
            }
        } else if ext == "gif" {
            // Animated GIF (manim) — display in WKWebView for animation support
            outputPlaceholderLabel.isHidden = true
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
            outputPlaceholderLabel.isHidden = true
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
                outputPlaceholderLabel.isHidden = true
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
