#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u real_test.py 2>&1 | tee data/real.out
