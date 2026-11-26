#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u probe.py 2>&1 | tee probe.log
echo "DONE" >> probe.log
