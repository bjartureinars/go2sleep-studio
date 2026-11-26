#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u capture.py data/idx.log 4 5a3800 5a3e00 5a3f00 5a0b00 5a0200 5a0300 5a0c00 5a4200 5a4300 5a4400 2>&1 | tee data/idx.out
