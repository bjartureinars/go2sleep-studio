#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u capture.py "$@" 2>&1 | tee "${1%.log}.out"
