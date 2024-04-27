#!/bin/bash

# Input from user
read -p "Enter a string: " input

# Remove "0x" prefix
input=${input#"0x"}

# Reverse the string
reversed=$(echo "$input" | rev)

# Insert spaces every two characters
spaced=$(echo "$reversed" | sed 's/../& /g')

# Print the final result
echo "Modified string: $spaced"

main() {
    local output="02 4c 57 52 47 $spaced 00 00 00 eb"
    echo $output
}

main