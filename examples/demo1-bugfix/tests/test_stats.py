import pytest

from mathkit import clamp, mean, median


def test_mean_of_single_value():
    assert mean([4]) == 4


def test_mean_of_several_values():
    assert mean([1, 2, 3, 4]) == 2.5


def test_mean_empty_raises():
    with pytest.raises(ValueError):
        mean([])


def test_median_odd_length_sorted_input():
    assert median([1, 2, 3]) == 2


def test_median_odd_length_unsorted_input():
    assert median([3, 1, 2]) == 2


def test_median_even_length_unsorted_input():
    assert median([4, 1, 3, 2]) == 2.5


def test_median_empty_raises():
    with pytest.raises(ValueError):
        median([])


def test_clamp_inside_range_is_unchanged():
    assert clamp(5, 0, 10) == 5


def test_clamp_below_range_returns_lo():
    assert clamp(-3, 0, 10) == 0


def test_clamp_above_range_returns_hi():
    assert clamp(42, 0, 10) == 10
