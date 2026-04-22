---
name: pygments
import: pygments
version: 2.18
category: Terminal
tags: syntax, highlight, code
bundled: true
---

# Pygments

**Syntax highlighting** for hundreds of languages. Pure Python — bundled unchanged.

## Highlight a string

```python
from pygments import highlight
from pygments.lexers import PythonLexer, JsonLexer, get_lexer_by_name
from pygments.formatters import TerminalFormatter, HtmlFormatter

code = """
def fib(n):
    return n if n < 2 else fib(n-1) + fib(n-2)
"""

# ANSI-coloured for the terminal / editor output
print(highlight(code, PythonLexer(), TerminalFormatter()))

# HTML with inline styles (useful inside a WKWebView)
print(highlight(code, PythonLexer(), HtmlFormatter(full=True, style="monokai")))
```

## Auto-detect the language

```python
from pygments.lexers import guess_lexer, guess_lexer_for_filename

lex = guess_lexer_for_filename("app.js", "const x = 1;")
lex = guess_lexer("SELECT * FROM users WHERE id = 1;")
print(lex.name)
```

## Available lexers / formatters / styles

```python
from pygments.lexers import get_all_lexers
from pygments.styles import get_all_styles
from pygments.formatters import get_all_formatters

for name, aliases, _, _ in sorted(get_all_lexers()):
    print(name, aliases)
print("styles:", sorted(get_all_styles()))
print("formatters:", sorted(f.name for f in get_all_formatters()))
```

## Custom style

```python
from pygments.token import Keyword, Name, Number, Punctuation
from pygments.style import Style

class MyStyle(Style):
    default_style = ""
    styles = {
        Keyword:       "bold #ff8",
        Name.Function: "#8cf",
        Number:        "#fa8",
        Punctuation:   "#aaa",
    }
```

## Use inside the editor

The CodeBench editor does its own syntax highlighting (Monaco-backed), so you only need Pygments if you're:
- Writing code that outputs syntax-highlighted text / HTML
- Building a Jupyter-like rendering pipeline
- Generating docs with syntax-highlighted snippets

## iOS notes

- No native dependencies. Works anywhere Python runs.
- Pairs nicely with **rich** — Rich's `Syntax` renderer uses Pygments under the hood.
