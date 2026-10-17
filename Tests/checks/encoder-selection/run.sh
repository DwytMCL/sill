#!/bin/bash
# Coordinator mode gate/status checks. No host, permission, capture, VT or network execution.
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
python3 "$here/../module.py" "$name" "$root" "$out/check"
