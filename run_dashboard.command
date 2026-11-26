#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u bridge.py 2>&1 | tee bridge.log
