#!/bin/bash

install_jq(){
    OS=$(uname -s)
    if [[ "$OS" == "Darwin" ]]; then
        OS="macos"
    elif [[ "$OS" == "Linux" ]]; then
        OS="linux"
    else
        echo "Unsupported OS: $OS"
        exit 1
    fi

    ARCH=$(uname -m)

    JQ_BIN="/tmp/jq"
    url="https://github.com/jqlang/jq/releases/latest/download/jq-${OS}-${ARCH}"
    curl -L -o $JQ_BIN $url
    chmod +x $JQ_BIN

}

install_hcl2json(){
    OS=$(uname -s)
    if [[ "$OS" == "Darwin" ]]; then
        OS="darwin"
    elif [[ "$OS" == "Linux" ]]; then
        OS="linux"
    else
        echo "Unsupported OS: $OS"
        exit 1
    fi

    ARCH=$(uname -m)

    HCL2JSON_BIN="./hcl2json"

    url="https://github.com/tmccombs/hcl2json/releases/latest/download/hcl2json_${OS}_${ARCH}"
    echo $url
    curl -L -o $HCL2JSON_BIN $url
    chmod +x $HCL2JSON_BIN
}


INPUT_FILE_JSON="$1"
if [ -z "$INPUT_FILE_JSON" ]; then
    echo "Usage: $0 <input_file.json>"
    exit 1
fi

JQ_BIN=$(which jq)
if [ $? -ne 0 ]; then
    install_jq
fi

HCL2JSON_BIN=$(which hcl2json)
if [ $? -ne 0 ]; then
    install_hcl2json
fi

# Read entire JSON array into a variable
json_data=$(cat "$INPUT_FILE_JSON")

# Use jq to get the length of array
length=$($JQ_BIN length <<<"$json_data")

# Create a temporary file to store updated objects
tmpfile=$(mktemp)

> "$tmpfile"

for ((i=0; i<length; i++)); do
  # Extract ith object
  obj=$($JQ_BIN ".[$i]" <<<"$json_data")
  
  JSON_PATH=".VCSConfig.iacInputData.data"

  # Extract the value at JSON_PATH from the object
  val=$($JQ_BIN -c "$JSON_PATH" <<<"$obj")

  # If val is null or not an object, skip
  if [[ "$val" == "null" || $($JQ_BIN 'type' <<<"$val") != "\"object\"" ]]; then
    echo "$obj" >> "$tmpfile"
    continue
  fi

  # Initialize new_val as empty object
  new_val="{}"

  # Loop over key-value pairs in val
  keys=$($JQ_BIN -r 'keys[]' <<<"$val")
  for key in $keys; do
    # Get the string value for the key
    value=$($JQ_BIN --arg k "$key" '.[$k]' <<<"$val" | sed 's/\\"/"/g')
    value="${value%\"}"
    value="${value#\"}"
    value="temp = $value"

    # Heuristic: if value contains '=', treat as HCL string
    if [[ "$value" == *"="* ]]; then
      # Convert HCL to JSON using hcl2json
      parsed=$(echo -e "$value" | $HCL2JSON_BIN | $JQ_BIN -c '.temp')
      if [[ $? -eq 0 && "$parsed" != "" ]]; then
        # Add parsed json as the key's value
        new_val=$($JQ_BIN --arg k "$key" --argjson v "$parsed" '. + {($k): $v}' <<<"$new_val")
      else
        # If parse fails, keep original string
        echo "parsing failed: $value"
        new_val=$($JQ_BIN --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$new_val")
      fi
    else
      # Not HCL, keep as string
      new_val=$($JQ_BIN --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$new_val")
    fi
  done

  # Update the object by assigning new_val back at JSON_PATH
  updated_obj=$($JQ_BIN --argjson nv "$new_val" "$JSON_PATH = \$nv" <<<"$obj")

  # Save updated object
  echo "$updated_obj" >> "$tmpfile"
done

# Combine updated objects into an array and overwrite the original file
$JQ_BIN -s '.' "$tmpfile" > "$INPUT_FILE_JSON"

rm "$tmpfile" $HCL2JSON_BIN $JQ_BIN