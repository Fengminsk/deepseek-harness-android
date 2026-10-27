"""Compile the actual test parser regexes with ICU4C, Android Pattern's regex backend.

This is host compatibility evidence, not an Android device acceptance result.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re


class ParseError(ctypes.Structure):
    _fields_ = [('line', ctypes.c_int32), ('offset', ctypes.c_int32),
                ('pre', ctypes.c_uint16 * 16), ('post', ctypes.c_uint16 * 16)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--icu-library', type=Path, required=True)
    parser.add_argument('--symbol-suffix', default='')
    args = parser.parse_args()
    suffix = '_' + args.symbol_suffix if args.symbol_suffix else ''
    library = args.icu_library.resolve(strict=True)
    search = os.add_dll_directory(str(library.parent)) if os.name == 'nt' else None
    try:
        icu = ctypes.CDLL(str(library))
    finally:
        if search is not None:
            search.close()
    compile_regex = getattr(icu, 'uregex_open' + suffix)
    compile_regex.argtypes = [ctypes.POINTER(ctypes.c_uint16), ctypes.c_int32, ctypes.c_uint32,
                             ctypes.POINTER(ParseError), ctypes.POINTER(ctypes.c_int32)]
    compile_regex.restype = ctypes.c_void_p
    close_regex = getattr(icu, 'uregex_close' + suffix)
    close_regex.argtypes = [ctypes.c_void_p]

    source = (Path(__file__).resolve().parent.parent / 'android/app/src/androidTest/java/'
              'com/minnnng/dsh_android/LinuxVmGuestObservation.java').read_text(encoding='utf-8')
    literal = r'"((?:[^"\\]|\\.)*)"'
    header = re.search(r'HEADER = Pattern\.compile\(' + literal + r'\);', source)
    process = re.search(r'Pattern app = Pattern\.compile\(' + literal
                        + r'\s*\+ Pattern\.quote\(expected\) \+ ' + literal + r'\);', source)
    if header is None or process is None:
        raise AssertionError('Actual parser regex source was not found; update the owning check')
    decode = lambda text: json.loads('"' + text + '"')
    patterns = [decode(header[1]), decode(process[1]) + r'\Qexact.fixture.process\E' + decode(process[2])]

    def compilation(pattern):
        raw = pattern.encode('utf-16-le')
        chars = (ctypes.c_uint16 * (len(raw) // 2)).from_buffer_copy(raw)
        status, where = ctypes.c_int32(), ParseError()
        handle = compile_regex(chars, len(chars), 0, ctypes.byref(where), ctypes.byref(status))
        if handle:
            close_regex(handle)
        return status.value, where.offset

    for index, pattern in enumerate(patterns):
        status, offset = compilation(pattern)
        if status > 0:
            raise AssertionError(f'Actual parser regex {index} failed ICU compilation: code={status}, offset={offset}')
        # The exact previous defect must fail on this backend, unlike OpenJDK Pattern.
        before = pattern.rsplit(r'\}', 1)
        if len(before) != 2:
            raise AssertionError('Missing explicitly escaped literal closing brace')
        status, offset = compilation('}'.join(before))
        if status <= 0:
            raise AssertionError('This backend did not reproduce the unescaped-brace defect')
        print(f'Pattern {index}: actual source accepted; prior unescaped brace rejected (code={status}, offset={offset})')
    print(f'ICU4C source regex compatibility passed: {library.name}; Android execution remains unverified')


if __name__ == '__main__':
    main()
