#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u replay12.py "$@" 2>&1 | tee data/replay.out
