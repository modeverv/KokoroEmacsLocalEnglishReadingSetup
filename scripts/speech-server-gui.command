#!/bin/zsh
cd "${0:A:h:h}" || exit 1
exec .venv/bin/python -m speech_http.gui "$@"
