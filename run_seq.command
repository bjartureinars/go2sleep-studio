#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u seq_test.py 2>&1 | tee data/seq.out
