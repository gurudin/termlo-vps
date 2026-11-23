"""Continue the bundled installer after its POSIX preflight and runtime setup."""
import sys

from termlo import main

main(preflight_dir=sys.argv.pop(1))
