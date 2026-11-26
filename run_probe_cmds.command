#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u probe_cmds.py 2>&1 | tee data/probe_cmds.out
