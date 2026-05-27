"""
codebench_debug_target.py — small script to step through under
the visual debugger.

Run with:
    debug-gui codebench_debug_target.py

What you should see in CodeBench:

  1. Floating toolbar appears at the top of the editor.
  2. The editor focuses on this file and a golden arrow paints
     the gutter at the first line of fibonacci().
  3. Tap the variable-inspector icon (rightmost in the toolbar) —
     panel slides in from the right showing Locals + Globals.
  4. Step Over (⏭) advances one line at a time.
  5. Step Into (⤓) descends into is_prime().
  6. Step Out (⤴) returns to the caller.
  7. Continue (▶) runs to completion.
  8. Toolbar disappears when the script ends.
"""

import math


def is_prime(n: int) -> bool:
    if n < 2:
        return False
    if n == 2:
        return True
    if n % 2 == 0:
        return False
    for i in range(3, int(math.isqrt(n)) + 1, 2):
        if n % i == 0:
            return False
    return True


def fibonacci(limit: int) -> list:
    """Return Fibonacci numbers up to `limit` (inclusive)."""
    a, b = 0, 1
    out = [a]
    while b <= limit:
        out.append(b)
        a, b = b, a + b
    return out


def main() -> None:
    fibs = fibonacci(100)
    primes = [n for n in fibs if is_prime(n)]
    print(f"Fibonacci numbers up to 100:     {fibs}")
    print(f"Fibonacci numbers that are prime: {primes}")
    print(f"Count: {len(primes)} primes among {len(fibs)} fibs")


if __name__ == "__main__":
    main()
