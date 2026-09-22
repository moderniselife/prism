# Legacy shim with one job: allow `bdist_wheel --plat-name` so each wheel
# is tagged for the OS/arch whose Go binary it bundles. (setuptools strips
# unknown options under `python -m build`; this path keeps working.)
from setuptools import setup

setup()
