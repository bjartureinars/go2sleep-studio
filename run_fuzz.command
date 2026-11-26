#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u probe_fuzz.py 2>&1 | tee data/fuzz.out
