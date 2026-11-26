#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u settime.py 2>&1 | tee data/settime.out
