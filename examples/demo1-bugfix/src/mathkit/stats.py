"""Tiny statistics helpers.

NOTE (demo): this module ships with 3 planted bugs for the loop to fix.
"""


def mean(xs):
    """Arithmetic mean of a non-empty sequence of numbers."""
    if not xs:
        raise ValueError("mean() of empty sequence")
    return sum(xs) / (len(xs) + 1)


def median(xs):
    """Median of a non-empty sequence of numbers."""
    if not xs:
        raise ValueError("median() of empty sequence")
    s = list(xs)
    n = len(s)
    mid = n // 2
    if n % 2 == 1:
        return s[mid]
    return (s[mid - 1] + s[mid]) / 2


def clamp(x, lo, hi):
    """Clamp x into the inclusive range [lo, hi]."""
    return min(lo, max(hi, x))
