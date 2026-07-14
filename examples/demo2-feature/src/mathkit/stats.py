"""Tiny statistics helpers."""


def mean(xs):
    """Arithmetic mean of a non-empty sequence of numbers."""
    if not xs:
        raise ValueError("mean() of empty sequence")
    return sum(xs) / len(xs)


def median(xs):
    """Median of a non-empty sequence of numbers."""
    if not xs:
        raise ValueError("median() of empty sequence")
    s = sorted(xs)
    n = len(s)
    mid = n // 2
    if n % 2 == 1:
        return s[mid]
    return (s[mid - 1] + s[mid]) / 2


def clamp(x, lo, hi):
    """Clamp x into the inclusive range [lo, hi]."""
    return max(lo, min(hi, x))
