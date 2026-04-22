---
name: rich
import: rich
version: latest (install via pip)
category: Terminal
tags: tui, color, table, progress, markdown
bundled: false
install: rich
---

# Rich

**Rich text and beautiful formatting in the terminal.** NOT bundled by default — this is the canonical "pip install me" demo. Open the **Libraries ▸ Install** tab and tap `rich`. The install takes ~10 seconds.

Once installed, the standalone template `pip_demo.py` in your Workspace folder shows you every feature below at once.

## Basic print

```python
from rich import print

print("[bold red]Error:[/] file not found")
print({"name": "Ada", "age": 36, "skills": ["python", "swift", "c"]})
```

## Console + panel

```python
from rich.console import Console
from rich.panel import Panel

c = Console()
c.print(Panel.fit("Hello from Rich!", title="greeting", border_style="green"))
```

## Tables

```python
from rich.table import Table

tbl = Table(title="Sales", show_header=True, header_style="bold magenta")
tbl.add_column("Product", style="cyan")
tbl.add_column("Units",  justify="right")
tbl.add_column("Revenue", style="green", justify="right")
tbl.add_row("Widget",  "128", "$1,280")
tbl.add_row("Gadget",  "42",  "$840")
tbl.add_row("Gizmo",   "7",   "$175")
c.print(tbl)
```

## Progress bars

```python
from rich.progress import Progress, BarColumn, TextColumn, TimeRemainingColumn
import time

with Progress(
    TextColumn("[progress.description]{task.description}"),
    BarColumn(),
    "{task.percentage:>3.0f}%",
    TimeRemainingColumn(),
) as progress:
    task = progress.add_task("[cyan]Crunching…", total=100)
    for _ in range(100):
        time.sleep(0.02)
        progress.update(task, advance=1)
```

## Tracking a simple iterable

```python
from rich.progress import track
for _ in track(range(1000), description="Processing…"):
    ...
```

## Tree

```python
from rich.tree import Tree
t = Tree("~/Documents")
d = t.add("Workspace")
d.add("main.py")
d.add("pip_demo.py")
d2 = t.add("site-packages (user)")
d2.add("rich/")
c.print(t)
```

## Markdown rendering

```python
from rich.markdown import Markdown
c.print(Markdown("# Hello\n\n- one\n- two\n- [link](https://example.com)"))
```

## Syntax highlighting

```python
from rich.syntax import Syntax
s = Syntax("def hi():\n    print('hello')\n", "python", theme="monokai", line_numbers=True)
c.print(s)
```

## Prompt for input

```python
from rich.prompt import Prompt, Confirm
name = Prompt.ask("[cyan]What is your name?[/]", default="world")
if Confirm.ask("Shall we continue?"):
    c.print(f"Hi, {name}!")
```

## iOS notes

- Terminal colors require `Console(force_terminal=True, color_system="truecolor")` to render inside the editor's output pane — otherwise Rich auto-detects "no TTY" and goes monochrome.
- Unicode drawing characters render correctly in the default monospaced font.
- Animations (live displays, spinners) work but may stutter when the editor redraws — don't rely on them for timing.
