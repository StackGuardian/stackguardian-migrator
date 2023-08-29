import json

def edit_json(input_file, output_file):
    # Read the data from the input JSON file
    with open(input_file, 'r') as f:
        data = json.load(f)

    # Perform edits on the data (example: adding a new key-value pair)
    data['new_key'] = 'new_value'

    # Write the edited data to the output JSON file
    with open(output_file, 'w') as f:
        json.dump(data, f, indent=4)

# Replace 'input.json' and 'output.json' with your file names
edit_json('input.json', 'output.json')