#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u capture.py data/dump.log 8 5a3b00 5a3c00 2>&1 | tee data/dump.out
