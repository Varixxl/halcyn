#!/usr/bin/env bash
# Writes tidal.properties (gitignored) with the Tidal app keys the tidalapi Python package
# ships. rust/build.rs bakes them into the core so Tidal's lossless sign-in works; without
# the file, Halcyn builds fine and simply offers no Tidal. HALCYN_PYTHON picks the Python
# that has tidalapi (`pip install tidalapi`).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
py=${HALCYN_PYTHON:-python3}
"$py" - "$here/tidal.properties" <<'PY'
import sys, tidalapi
c = tidalapi.Config()
open(sys.argv[1], "w").write(f"client_id={c.client_id_pkce}\nclient_secret={c.client_secret_pkce}\n")
print("wrote", sys.argv[1])
PY
