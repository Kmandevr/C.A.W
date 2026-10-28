#!/bin/bash
# Runs a Serena hook (e.g. `remind`, `cleanup`) if Serena is installed; does nothing otherwise,
# so a session without Serena never errors on these hooks.
command -v serena-hooks >/dev/null 2>&1 || exit 0
exec serena-hooks "$@"
