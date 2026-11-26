#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u probe2.py 2>&1 | tee probe2.log
