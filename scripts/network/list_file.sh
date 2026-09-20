#!/usr/bin/env bash

# Read a line- or comma-separated network list as one config-ready CSV value.
network_list_csv() {
  local file="$1"
  awk '
    BEGIN { list = "" }
    {
      gsub(/\r/, "")
      gsub(/,/, "\n")
      count = split($0, entries, /\n/)
      for (i = 1; i <= count; i++) {
        entry = entries[i]
        gsub(/^[ \t]+|[ \t]+$/, "", entry)
        if (entry != "") {
          if (list != "") list = list ","
          list = list entry
        }
      }
    }
    END { print list }
  ' "$file"
}
