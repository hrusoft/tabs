#!/usr/bin/env python3
"""Fails if a warning stands in the build. Part of `make check`.

Swift 6.4's -warnings-as-errors (SWIFT_TREAT_WARNINGS_AS_ERRORS, on project-wide)
doesn't escalate AppKit's main-actor isolation warnings, so those build green
and only this check catches them. An incremental build prints warnings only for
the files it recompiled, but the compiler also keeps each file's diagnostics in
a .dia beside its object file, rewritten whenever the file is compiled again.
So after any build, the .dia files of every target's current sources say what
a clean build would print, for a fraction of a second instead of a clean build.
(The linker's warnings can't stand: -fatal_warnings fails the link.)

    Scripts/check-warnings.py <build log>   the .dia files of build/DerivedData
                                            ($CONFIG), and the warnings that
                                            build printed (a script's, an asset
                                            catalog's: they leave no .dia)
    Scripts/check-warnings.py --clean       a clean build-for-testing of every
                                            target in build/DerivedData-warnings
                                            and what it printed: also the warnings
                                            of steps the last build didn't run
                                            again (make check-release)
"""

import ctypes
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = os.environ.get("CONFIG", "Debug")
# A warning line as xcodebuild prints it: the diagnostic itself (a path, or `ld:`),
# not the indented source excerpt the compiler prints under it.
PRINTED = re.compile(r"^[^\s].*warning: ")
WARNING = 2  # CXDiagnostic_Warning
LOCATION_AND_COLUMN = 0x1 | 0x2  # CXDiagnostic_DisplaySourceLocation | DisplayColumn


class CXString(ctypes.Structure):
    _fields_ = [("data", ctypes.c_void_p), ("flags", ctypes.c_uint)]


def libclang():
    clang = subprocess.run(["xcrun", "--find", "clang"], capture_output=True, text=True, check=True).stdout.strip()
    lib = ctypes.CDLL(str(Path(clang).parent.parent / "lib/libclang.dylib"))
    lib.clang_loadDiagnostics.restype = ctypes.c_void_p
    lib.clang_loadDiagnostics.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(CXString)]
    lib.clang_getNumDiagnosticsInSet.argtypes = [ctypes.c_void_p]
    lib.clang_getDiagnosticInSet.restype = ctypes.c_void_p
    lib.clang_getDiagnosticInSet.argtypes = [ctypes.c_void_p, ctypes.c_uint]
    lib.clang_getDiagnosticSeverity.argtypes = [ctypes.c_void_p]
    lib.clang_formatDiagnostic.restype = CXString
    lib.clang_formatDiagnostic.argtypes = [ctypes.c_void_p, ctypes.c_uint]
    lib.clang_getCString.restype = ctypes.c_char_p
    lib.clang_getCString.argtypes = [CXString]
    lib.clang_disposeString.argtypes = [CXString]
    lib.clang_disposeDiagnosticSet.argtypes = [ctypes.c_void_p]
    return lib


def current_diagnostic_files(intermediates):
    """Every .dia of a source each target still compiles, and each module's own.

    A deleted source's .dia stays behind, so a target's file list (the sources
    its last build compiled) decides which are current."""
    for lists in intermediates.glob(f"**/{CONFIG}/**/Objects-normal/*/*.SwiftFileList"):
        directory = lists.parent
        sources = {Path(line.strip()).stem for line in lists.read_text().splitlines() if line.strip()}
        module = lists.stem
        for dia in directory.glob("*.dia"):
            name = dia.stem
            if name in sources or name in (f"{module}-primary-emit-module", f"{module}-dependency-scan"):
                yield dia


def compiler_warnings(intermediates):
    lib = libclang()
    found = set()
    for dia in current_diagnostic_files(intermediates):
        error, message = ctypes.c_int(), CXString()
        diagnostics = lib.clang_loadDiagnostics(str(dia).encode(), ctypes.byref(error), ctypes.byref(message))
        if not diagnostics:
            continue
        for index in range(lib.clang_getNumDiagnosticsInSet(diagnostics)):
            diagnostic = lib.clang_getDiagnosticInSet(diagnostics, index)
            if lib.clang_getDiagnosticSeverity(diagnostic) != WARNING:
                continue
            text = lib.clang_formatDiagnostic(diagnostic, LOCATION_AND_COLUMN)
            line = lib.clang_getCString(text).decode()
            lib.clang_disposeString(text)
            # A source that is gone (its whole target deleted) warns no more.
            path = line.split(":", 1)[0]
            if not path.startswith("/") or Path(path).exists():
                found.add(line)
        lib.clang_disposeDiagnosticSet(diagnostics)
    return found


def printed_warnings(log):
    return {line.rstrip() for line in log.read_text(errors="replace").splitlines() if PRINTED.match(line)}


def clean_build():
    derived = ROOT / "build/DerivedData-warnings"
    log = ROOT / "build/warnings.log"
    shutil.rmtree(derived, ignore_errors=True)
    command = ["xcodebuild", "-project", "Tabs.xcodeproj", "-scheme", "Tabs", "-configuration", CONFIG,
               "-derivedDataPath", str(derived), "-destination", "platform=macOS", "-skipPackagePluginValidation",
               "-quiet", "build-for-testing"]
    with log.open("w") as output:
        status = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT).returncode
    shutil.rmtree(derived, ignore_errors=True)
    if status != 0:
        print(log.read_text(errors="replace"))
        sys.exit("check-warnings: the build failed")
    return printed_warnings(log), log


def main():
    if sys.argv[1:] == ["--clean"]:
        warnings, log = clean_build()
        source = "a clean build of every target"
    elif len(sys.argv) == 2:
        log = Path(sys.argv[1])
        warnings = compiler_warnings(ROOT / "build/DerivedData/Build/Intermediates.noindex") | printed_warnings(log)
        source = f"the {CONFIG} build of every target"
    else:
        sys.exit(__doc__)
    if warnings:
        print("\n".join(sorted(warnings)))
        sys.exit(f"check-warnings: {len(warnings)} warning(s) in {source}; the build's log is {log}")
    print(f"check-warnings: {source} has no warnings")


if __name__ == "__main__":
    main()
