"""thermocouple_k.py - NIST ITS-90 Type K thermocouple math.

Coefficients verified 2026-10-15 against two independent sources that
agree digit-for-digit: NIST's own its90.nist.gov/RefFunctions +
its90.nist.gov/InvFunctions pages, and the open-source
thermocouples_reference_devel package (which explicitly reproduces NIST's
reference tables, from its create_tables_NIST.py). Not typed from memory -
a transcription error here would silently produce a wrong temperature
every time, so this was worth getting from a real source rather than
guessing.

Two directions:
- emf_mv(temp_c): forward function, °C -> mV. Used to convert the cold-
  junction REFERENCE temperature into its equivalent millivolt offset.
- temp_c(emf_mv): inverse function, mV -> °C. Used on the final
  compensated EMF (measured mV + reference junction's equivalent mV) to
  get the real hot-junction temperature.

Cold-junction compensation itself (the actual point of this module):
    compensated_temp_c(measured_mv, reference_junction_temp_c)
measured_mv is the raw voltage read directly off the probes (e.g. via
CONFigure:VOLT:DC); reference_junction_temp_c is the real temperature at
the probe tips/clips where the thermocouple wire's dissimilar metal
actually meets the probe (NOT the meter's own input terminals - see
2026-10-15 discussion: clipping probes onto bare TC wire moves the real
cold junction out to the clips, not the meter's banana jacks).
"""

# Forward function (°C -> mV), NIST ITS-90 Type K reference function.
# Range -270.000 to 0.000 °C (polynomial order 10).
_FWD_COEFFS_NEG = [
    0.000000000000E+00,
    0.394501280250E-01,
    0.236223735980E-04,
    -0.328589067840E-06,
    -0.499048287770E-08,
    -0.675090591730E-10,
    -0.574103274280E-12,
    -0.310888728940E-14,
    -0.104516093650E-16,
    -0.198892668780E-19,
    -0.163226974860E-22,
]
# Range 0.000 to 1372.000 °C (polynomial order 9).
_FWD_COEFFS_POS = [
    -0.176004136860E-01,
    0.389212049750E-01,
    0.185587700320E-04,
    -0.994575928740E-07,
    0.318409457190E-09,
    -0.560728448890E-12,
    0.560750590590E-15,
    -0.320207200030E-18,
    0.971511471520E-22,
    -0.121047212750E-25,
]
# Gaussian correction term, added only for T >= 0°C:
# a0 * exp(a1 * (T - a2)^2)
_A0 = 0.118597600000E+00
_A1 = -0.118343200000E-03
_A2 = 0.126968600000E+03

# Inverse function (mV -> °C), NIST ITS-90 Type K inverse function.
# Each entry: (min_mv, max_mv, [d0, d1, ...]).
_INV_SUBRANGES = [
    (-5.891, 0.0, [
        0.0000000E+00,
        2.5173462E+01,
        -1.1662878E+00,
        -1.0833638E+00,
        -8.9773540E-01,
        -3.7342377E-01,
        -8.6632643E-02,
        -1.0450598E-02,
        -5.1920577E-04,
        0.0000000E+00,
    ]),
    (0.0, 20.644, [
        0.000000E+00,
        2.508355E+01,
        7.860106E-02,
        -2.503131E-01,
        8.315270E-02,
        -1.228034E-02,
        9.804036E-04,
        -4.413030E-05,
        1.057734E-06,
        -1.052755E-08,
    ]),
    (20.644, 54.886, [
        -1.318058E+02,
        4.830222E+01,
        -1.646031E+00,
        5.464731E-02,
        -9.650715E-04,
        8.802193E-06,
        -3.110810E-08,
        0.0,
        0.0,
        0.0,
    ]),
]


def emf_mv(temp_c):
    """Forward function: °C -> mV. Valid -270 to 1372 °C."""
    coeffs = _FWD_COEFFS_NEG if temp_c < 0 else _FWD_COEFFS_POS
    result = sum(c * (temp_c ** i) for i, c in enumerate(coeffs))
    if temp_c >= 0:
        result += _A0 * _math_exp(_A1 * (temp_c - _A2) ** 2)
    return result


def temp_c(emf):
    """Inverse function: mV -> °C. Valid -5.891 to 54.886 mV
    (-200 to 1372 °C)."""
    for lo, hi, coeffs in _INV_SUBRANGES:
        if lo <= emf <= hi:
            return sum(d * (emf ** i) for i, d in enumerate(coeffs))
    raise ValueError(f"{emf} mV is outside Type K's valid range (-5.891 to 54.886 mV)")


def compensated_temp_c(measured_mv, reference_junction_temp_c):
    """The actual cold-junction-compensated conversion. measured_mv is the
    raw voltage read off the probes; reference_junction_temp_c is the real
    temperature at the probe tips/clips (the actual cold junction in this
    setup - see module docstring)."""
    reference_mv = emf_mv(reference_junction_temp_c)
    return temp_c(measured_mv + reference_mv)


def _math_exp(x):
    import math
    return math.exp(x)
