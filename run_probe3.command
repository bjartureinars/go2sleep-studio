#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u probe3.py 2>&1 | tee probe3.log
