---
name: psutil
import: psutil
version: 5.9.8
category: System
tags: cpu, memory, disk, process, battery
bundled: true
---

# psutil

**Process and system utilities.** Cross-compiled for iOS arm64 using the macOS code path (they share mach/BSD APIs). Most system-level introspection works; some process-iteration calls are sandboxed.

## System-wide CPU

```python
import psutil

psutil.cpu_count(logical=True)           # 8 on an M-series iPad
psutil.cpu_count(logical=False)          # physical cores

psutil.cpu_percent(interval=0.5)         # overall load %
psutil.cpu_percent(interval=0.5, percpu=True)   # per-core list

psutil.cpu_freq()                        # current / min / max MHz
psutil.cpu_stats()                       # ctx_switches, interrupts, ...
```

## Memory

```python
vm = psutil.virtual_memory()
print(vm.total / 1e9, "GB total")
print(vm.available / 1e9, "GB available")
print(vm.percent, "%")

sw = psutil.swap_memory()     # usually 0 bytes on iOS
```

## Disk

```python
psutil.disk_usage("/")        # namedtuple: total, used, free, percent
psutil.disk_partitions()      # list of mounts

# I/O counters are aggregated for the app's sandbox
psutil.disk_io_counters()     # read_count, write_count, read_bytes, ...
```

## Network (per-interface)

```python
for name, stats in psutil.net_io_counters(pernic=True).items():
    print(name, "→ sent", stats.bytes_sent, "recv", stats.bytes_recv)

psutil.net_if_addrs()       # IP/MAC per interface
psutil.net_if_stats()        # isup, speed, mtu
```

## Battery

```python
b = psutil.sensors_battery()
if b:
    print(f"{b.percent:.0f}%  {'charging' if b.power_plugged else 'on battery'}")
    # b.secsleft if you want estimated runtime
```

## Current process

```python
p = psutil.Process()           # "self" — the OfflinAi app
print(p.name())                # e.g. "OfflinAi"
print(p.pid)
print(p.memory_info().rss / 1e6, "MB RSS")
print(p.cpu_percent(interval=0.5))
print(p.num_threads())
print(p.open_files())          # all fds the app has open
print(p.cmdline())
print(p.create_time())
print(p.status())

# CPU / IO counters for the process
p.cpu_times()         # user / system
p.io_counters()
```

## What works on iOS — the verified list

These pass 17/17 on a real device (see `psutil_test.py` in Workspace):

- `psutil.__version__`, `psutil.boot_time()`, `psutil.sensors_battery()`
- **CPU**: `cpu_count(logical=False)`, `cpu_percent()`, `cpu_times()`
- **Memory**: `virtual_memory()` (all fields — total, available, used, percent, active, inactive, wired)
- **Disk**: `disk_usage(path)` only — no partition / I/O counter enumeration
- **Own process** (`psutil.Process()`, not any other PID): `name()`, `pid`, `ppid()`, `memory_info()`, `memory_percent()`, `num_threads()`, `cpu_percent()`, `cpu_times()`, `create_time()`

## What does NOT work on iOS

These **crash the process** with `EXC_BAD_ACCESS` (null-deref in psutil's C ext when the iOS sandbox returns `NULL` from the underlying syscall). The bundled `psutil_test.py` hard-skips them; do the same in your own code.

| Call | Reason |
|---|---|
| `cpu_freq()` | IOKit iteration unsafe on iOS |
| `cpu_count(logical=True)` | `sysctl("hw.logicalcpu")` returns `None`; use `logical=False` |
| `swap_memory()` | `VM_SWAPUSAGE` sysctl not available |
| `disk_partitions()` | `getfsstat()` returns garbage pointer |
| `disk_io_counters()` | per-device IOKit counters sandbox-blocked |
| `net_io_counters()` / `net_if_addrs()` / `net_if_stats()` / `net_connections()` | `CTL_NET` sysctls + `getifaddrs()` sandboxed |
| `sensors_temperatures()` / `sensors_fans()` | returns `[]` on iOS |
| `Process.status()` | `PROC_PIDT_SHORTBSDINFO` returns null |
| `Process.cmdline()` | `KERN_PROCARGS2` sysctl blocked |
| `Process.exe()` / `Process.cwd()` | `proc_pidpath` / `VNODEPATHINFO` need entitlement |
| `Process.username()` / `uids()` / `gids()` | credential struct null on iOS |
| `Process.open_files()` / `connections()` / `children()` | proc_pidinfo restrictions |
| `psutil.pids()` / `process_iter()` | `AccessDenied` — can only see own PID |
| `psutil.users()` | `utmpx.getutxent()` returns null |

## Minimum-safe startup pattern

```python
import psutil

def cpu_info():
    return {
        "physical": psutil.cpu_count(logical=False),
        "load":     psutil.cpu_percent(interval=0.2),
        "times":    psutil.cpu_times()._asdict(),
    }

def mem_info():
    v = psutil.virtual_memory()
    return {"total": v.total, "used": v.used, "available": v.available, "percent": v.percent}

def self_proc():
    p = psutil.Process()
    return {
        "pid":       p.pid,
        "name":      p.name(),
        "rss_mb":    p.memory_info().rss / 1e6,
        "threads":   p.num_threads(),
        "cpu_pct":   p.cpu_percent(interval=0.2),
        "create":    p.create_time(),
    }

print(cpu_info())
print(mem_info())
print(self_proc())
```

## Useful snippets

### "Where is all the memory going?"

```python
vm = psutil.virtual_memory()
p = psutil.Process()
print(f"System: {vm.used/1e9:.2f} / {vm.total/1e9:.2f} GB  ({vm.percent}%)")
print(f"This app: {p.memory_info().rss/1e6:.1f} MB")
```

### Poll CPU load over time

```python
import time
samples = []
for _ in range(10):
    samples.append(psutil.cpu_percent(interval=0.1))
    time.sleep(0.4)
print("avg CPU %:", sum(samples)/len(samples))
```

### Watch battery drain for a minute

```python
import time
start = psutil.sensors_battery()
time.sleep(60)
end = psutil.sensors_battery()
if start and end:
    delta = start.percent - end.percent
    print(f"Lost {delta}% battery in 60s while charging={end.power_plugged}")
```
