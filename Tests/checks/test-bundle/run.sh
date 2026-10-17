#!/bin/bash
# Test-bundle identity namespace and update isolation. No Keychain operations, app, or network.
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
python3 "$here/../module.py" "$name" "$root" "$out/check"
