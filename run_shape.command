#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u shape_test.py 2>&1 | tee data/shape.out
