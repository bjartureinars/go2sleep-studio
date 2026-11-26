#!/bin/zsh
cd "$(dirname "$0")"
.venv/bin/python -u overnight_logger.py 2>&1 | tee -a data/overnight/logger.out
