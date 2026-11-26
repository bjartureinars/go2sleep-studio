#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u scan.py 2>&1 | tee scan.log
echo "DONE exit=$?" >> scan.log
