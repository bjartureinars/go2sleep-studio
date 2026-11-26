#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u clean_run.py 2>&1 | tee data/clean.out
