#!/usr/bin/env bash
set -euo pipefail

# Compatibility wrapper. The WS toolkit uses check-stack.sh as the main diagnostic entrypoint.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-stack.sh" "$@"
