"""Expected values for Tests/FontsMakerKitTests/Cu2quTests.swift, computed by fontTools.

Run with python3 -I. The Swift tests embed this script's output as literals,
so the Swift port is checked against fontTools without Python at test time.
Rerun and paste when the vectors change.

Random curves come from SplitMix64 (seed below), which the Swift test
reimplements, so both sides convert the same 1000 curves without storing them.
"""

import fontTools
from fontTools.cu2qu import curve_to_quadratic
from fontTools.cu2qu.errors import ApproxNotFoundError

MASK = (1 << 64) - 1
SEED = 0x2E2E_C0DE
COUNT = 1000
TOLERANCE = 1.0


class SplitMix64:
    def __init__(self, seed):
        self.state = seed & MASK

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
        return z ^ (z >> 31)


def random_curves():
    rng = SplitMix64(SEED)
    return [[(float(rng.next() % 1001), float(rng.next() % 1001)) for _ in range(4)] for _ in range(COUNT)]


def segments(curve, tolerance):
    try:
        return len(curve_to_quadratic(curve, tolerance)) - 2
    except ApproxNotFoundError:
        return 0


def swift_points(points):
    return "[" + ", ".join(f"({x!r}, {y!r})" for x, y in points) + "]"


print(f"// fontTools {fontTools.version}")
counts = [segments(c, TOLERANCE) for c in random_curves()]
# One base-36 digit per curve; 0 = ApproxNotFoundError.
digits = "0123456789abcdefghijklmnopqrstuvwxyz"
assert max(counts) < len(digits)
print("segment counts:", "".join(digits[n] for n in counts))
histogram = {n: counts.count(n) for n in sorted(set(counts))}
print("histogram:", histogram)

fixed = [
    ("exact quadratic", [(0, 0), (2, 2), (4, 2), (6, 0)], 0.1),
    ("fontTools AllQuadraticFalse cubic", [(0, 0), (0, 1), (2, 1), (2, 0)], 0.1),
    ("fontTools docstring curve", [(50, 50), (100, 100), (150, 100), (200, 50)], 1.0),
    ("collinear handles", [(0, 0), (1, 0), (2, 0), (3, 0)], 1.0),
    ("all points equal", [(5, 5), (5, 5), (5, 5), (5, 5)], 1.0),
    ("s-curve", [(0, 0), (400, 0), (-200, 600), (300, 700)], 1.0),
    ("tight loop", [(0, 0), (1000, 1000), (0, 1000), (1000, 0)], 1.0),
    ("font-like stroke edge", [(166.683, -13.867), (167.054, -13.681), (167.414, -13.487), (167.759, -13.281)], 1.0),
    ("font-like bowl", [(452.0, 386.5), (452.0, 512.75), (371.25, 600.0), (250.0, 600.0)], 1.0),
]
for name, curve, tolerance in fixed:
    result = curve_to_quadratic([tuple(map(float, p)) for p in curve], tolerance)
    print(f'("{name}", {swift_points(curve)}, {tolerance!r}, {swift_points(result)}),')
