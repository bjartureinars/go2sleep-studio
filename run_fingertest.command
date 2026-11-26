#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u fingertest.py 2>&1 | tee data/fingertest.out
