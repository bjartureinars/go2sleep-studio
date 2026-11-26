#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u ab_test.py 2>&1 | tee data/ab.out
