#!/bin/zsh
# Compatibility wrapper.
exec "${0:A:h}/build-app.sh" "$@"
