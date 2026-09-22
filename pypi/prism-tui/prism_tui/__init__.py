"""prism-tui launcher: execs the platform binary bundled in this wheel."""

import os
import sys

__version__ = "0.0.0"


def _binary():
    here = os.path.dirname(os.path.abspath(__file__))
    name = "prism-tui.exe" if os.name == "nt" else "prism-tui"
    return os.path.join(here, "bin", name)


def main():
    binary = _binary()
    if not os.path.isfile(binary):
        print(
            "prism-tui: bundled binary missing. This wheel is platform-specific — "
            "install the wheel matching your OS, or grab a static binary from "
            "https://github.com/moderniselife/prism/releases",
            file=sys.stderr,
        )
        raise SystemExit(1)
    os.execv(binary, [binary] + sys.argv[1:])
