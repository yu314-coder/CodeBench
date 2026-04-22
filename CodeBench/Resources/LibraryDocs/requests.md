---
name: requests
import: requests
version: 2.32+
category: Networking
tags: http, api, rest, json
bundled: true
---

# Requests

**The de-facto HTTP library for Python.** Pure-Python (with urllib3 under the hood) — bundled unmodified.

## GET

```python
import requests

r = requests.get("https://httpbin.org/get", params={"q": "ios"})
print(r.status_code, r.url)
print(r.json())              # dict
print(r.headers["content-type"])
```

## POST

```python
r = requests.post("https://httpbin.org/post",
                  json={"name": "Ada", "skills": ["python"]})
print(r.json()["json"])      # echoed back
```

## Form data + files

```python
r = requests.post("https://httpbin.org/post",
                  data={"field1": "value"},
                  files={"file": ("upload.txt", b"hello!", "text/plain")})
```

## Headers & auth

```python
r = requests.get("https://api.github.com/user",
                 headers={"Authorization": "Bearer YOUR_TOKEN",
                          "User-Agent": "OfflinAi/1.0"})

# Basic auth
r = requests.get("https://api.example.com", auth=("user", "pass"))
```

## Session (connection pooling, cookies)

```python
with requests.Session() as s:
    s.headers.update({"User-Agent": "OfflinAi"})
    s.get("https://httpbin.org/cookies/set/flavor/chocolate")
    r = s.get("https://httpbin.org/cookies")
    print(r.json())  # {'cookies': {'flavor': 'chocolate'}}
```

## Streaming downloads

```python
url = "https://example.com/large-file.zip"
with requests.get(url, stream=True) as r:
    r.raise_for_status()
    with open("/tmp/file.zip", "wb") as f:
        for chunk in r.iter_content(chunk_size=8192):
            f.write(chunk)
```

## Timeouts & retries

```python
# Always set a timeout on iOS — network can be flaky
try:
    r = requests.get("https://slow.example.com", timeout=5)
except requests.exceptions.Timeout:
    print("Request timed out")

# Quick retry helper (3 tries, 0.5s apart)
import time
for attempt in range(3):
    try:
        r = requests.get(url, timeout=5)
        break
    except requests.RequestException:
        if attempt == 2: raise
        time.sleep(0.5)
```

## Error handling

```python
try:
    r = requests.get(url, timeout=10)
    r.raise_for_status()             # HTTPError on 4xx / 5xx
except requests.exceptions.HTTPError as e:
    print(f"HTTP {e.response.status_code}: {e.response.text[:200]}")
except requests.exceptions.ConnectionError:
    print("Network unreachable")
except requests.exceptions.Timeout:
    print("Too slow")
```

## iOS notes

- iOS's **App Transport Security** (ATS) still applies when Python uses the system resolver for DNS. Plain HTTP is blocked by default — use HTTPS endpoints.
- The bundled **certifi** package provides the Mozilla CA bundle, so TLS validation just works.
- Background networking uses the app's URLSession mediator — if the app is backgrounded mid-request, the OS may suspend it.
- For `async` HTTP, install **httpx** via the Libraries tab (`pip install httpx`).
