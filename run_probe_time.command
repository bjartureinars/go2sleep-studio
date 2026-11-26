#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u probe_time.py 2>&1 | tee data/probe_time.out
