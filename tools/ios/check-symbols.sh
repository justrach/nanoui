#!/bin/sh
set -eu
binary_uuid=$(xcrun dwarfdump --uuid "$1" | awk '/^UUID:/ {print $2}')
symbols_uuid=$(xcrun dwarfdump --uuid "$2" | awk '/^UUID:/ {print $2}')
test -n "$binary_uuid"
test "$binary_uuid" = "$symbols_uuid"
# Look up app code, since DWARF for a runtime object alone is insufficient.
xcrun dwarfdump --name='(^|\.)main$' --regex "$2" | awk '
    /DW_TAG_subprogram/ { source = 0 }
    /DW_AT_decl_file.*examples\/counter\/main.zig/ { source = 1 }
    source && /DW_AT_decl_line/ { found = 1 }
    END { exit !found }
'
printf 'iOS release dSYM matches %s and resolves Counter main to source\n' "$binary_uuid"
