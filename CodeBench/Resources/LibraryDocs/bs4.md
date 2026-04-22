---
name: beautifulsoup4
import: bs4
version: 4.12+
category: Networking
tags: html, parser, scraping, xml
bundled: true
---

# BeautifulSoup (bs4)

**Parse HTML / XML** — good for scraping, cleaning, or extracting from saved web pages.

## Parse HTML

```python
from bs4 import BeautifulSoup

html = """
<html><body>
  <h1>Heading</h1>
  <p class="intro">Hello <b>world</b>!</p>
  <ul>
    <li><a href="/a">one</a></li>
    <li><a href="/b">two</a></li>
  </ul>
</body></html>
"""

soup = BeautifulSoup(html, "html.parser")   # stdlib parser, no extra deps
```

## Navigate & query

```python
soup.h1.text                  # "Heading"
soup.find("p", class_="intro").get_text(" ", strip=True)   # "Hello world !"

# CSS-like selectors
soup.select("ul > li > a")    # list of <a> tags
[a["href"] for a in soup.select("ul > li > a")]   # ['/a', '/b']

# find_all
for a in soup.find_all("a"):
    print(a.text, "→", a.get("href"))
```

## Combine with requests

```python
import requests, bs4

r = requests.get("https://example.com", timeout=10)
soup = bs4.BeautifulSoup(r.text, "html.parser")
title = soup.title.get_text()
links = [a.get("href") for a in soup.select("a[href]")]
```

## Modify the tree

```python
for a in soup.select("a"):
    a["rel"] = "noopener"
    a["target"] = "_blank"

# Remove nodes
for tag in soup.select(".ad, script, noscript"):
    tag.decompose()

# Re-emit as cleaned HTML
clean_html = str(soup)
```

## Extract all text cleanly

```python
# Strip script/style, collapse whitespace
for t in soup(["script", "style"]):
    t.decompose()
text = " ".join(soup.stripped_strings)
```

## Parse XML

```python
xml = "<root><item id='1'>hi</item><item id='2'>bye</item></root>"
soup = BeautifulSoup(xml, "xml")            # uses lxml if installed, else html.parser
for item in soup.find_all("item"):
    print(item["id"], "→", item.text)
```

## Performance notes

- The `html.parser` (stdlib) is bundled and ≈2–4× slower than lxml. For small pages it's fine.
- **lxml** is NOT bundled (needs libxml2/libxslt native libs that aren't shipped). Use **defusedxml** (via the Install tab) for safer XML parsing if you need XPath.
- For large documents, **selectolax** (pip-installable pure-Python) is another option.

## iOS notes

- `bs4` is pure Python; works exactly like on desktop.
- Good companion to **requests** — scrape a page, extract data, feed into **pandas** / **sklearn**.
