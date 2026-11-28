#!/bin/sh
set -eu
binary_uuid=$(xcrun dwarfdump --uuid "$1" | awk '/^UUID:/ {print $2}')
symbols_uuid=$(xcrun dwarfdump --uuid "$2" | awk '/^UUID:/ {print $2}')
test -n "$binary_uuid"
test "$binary_uuid" = "$symbols_uuid"
xcrun dwarfdump --debug-info "$2" | awk '/DW_TAG_compile_unit/ { found = 1 } END { exit !found }'
printf 'iOS release dSYM matches %s and contains debug information\n' "$binary_uuid"
