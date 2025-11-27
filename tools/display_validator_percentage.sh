#!/bin/bash

validators_data=$(./lumend q staking validators -o json)

# Calculate the total voting power
total_vp=$(echo "$validators_data" | jq '[.validators[].tokens | tonumber] | add')

# Loop through each validator and calculate the percentage
echo "$validators_data" | jq -r '.validators[] | "\(.description.moniker) \(.tokens)"' | while read -r moniker vp; do
    percentage=$(echo "scale=4; $vp * 100 / $total_vp" | bc -l)
    printf "%-10s: %10d ulmn (%6.2f%%)\n" "$moniker" "$vp" "$percentage"
done