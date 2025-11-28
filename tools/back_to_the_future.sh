#!/bin/bash

# --- CONFIGURATION ---
BINARY="lumend"              # Your binary name
TARGET_HEIGHT=17000            # The block you want to go back to
HOME_DIR="$HOME/.lumen"     # Your node directory
# ---------------------

# 1. Auto-detect current height (works offline)
# We grep the height from the validator state file to avoid needing 'jq'
STATE_FILE="$HOME_DIR/data/priv_validator_state.json"

if [ ! -f "$STATE_FILE" ]; then
    echo "Error: Could not find $STATE_FILE. Is the path correct?"
    exit 1
fi

CURRENT_HEIGHT=$(grep -oE '"height": "[0-9]+"' "$STATE_FILE" | grep -oE '[0-9]+')

# Safety check
if [ -z "$CURRENT_HEIGHT" ]; then
    echo "Error: Could not detect current height automatically."
    exit 1
fi

if [ "$CURRENT_HEIGHT" -le "$TARGET_HEIGHT" ]; then
    echo "Current height ($CURRENT_HEIGHT) is already below or equal to target ($TARGET_HEIGHT)."
    exit 0
fi

DIFF=$(($CURRENT_HEIGHT - $TARGET_HEIGHT))

# 2. Confirmation Prompt
echo "========================================"
echo "      COSMOS SURGICAL ROLLBACK"
echo "========================================"
echo "Current Height : $CURRENT_HEIGHT"
echo "Target Height  : $TARGET_HEIGHT"
echo "Blocks to wipe : $DIFF"
echo "========================================"
echo "Ensure your node is STOPPED before proceeding."
read -p "Press [Enter] to start rollback..."

# 3. The Loop
echo "Starting..."
for (( i=1; i<=DIFF; i++ ))
do
   # We use \r to overwrite the line for a cleaner UI
   echo -ne "Rolling back... ($i / $DIFF) \r"
   $BINARY rollback --home "$HOME_DIR" > /dev/null 2>&1
   
   if [ $? -ne 0 ]; then
       echo ""
       echo "Critical Error during rollback. Stopping."
       exit 1
   fi
done

echo ""
echo "Done! Chain is now at height $TARGET_HEIGHT."