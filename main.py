import json

def create_new_json(input_file1, input_file2):
    try:
        # Load data from the first input JSON file
        with open(input_file1, 'r') as f1:
            data1 = json.load(f1)        
        
        

        #patch the data to the sg_payload
        resources = (data1["resources"])
        env = []
        resource_names=[]
        for i in resources:
            if i["type"] == "tfe_variables":
                instances = i["instances"]
                for j in instances:
                   if j["attributes"]["env"]:
                    for k in j["attributes"]["env"]:
                     if k["category"] == "env":
                        env.append({k["name"] : k["value"]}) 
                   if j["attributes"]["variables"]: 
                    for k in j["attributes"]["variables"]:
                     if k["category"] == "env":
                        env.append({k["name"] : k["value"]})
                
            if i["type"] == "tfe_workspace":
                workspace_names = i["instances"]
                for j in workspace_names:
                    workspace_name = j["index_key"]
                    description = j["attributes"]["description"]
                    tags = j["attributes"]["tag_names"]
                    env = env
                    resource_names.append({"ResourceName": workspace_name, "Description" : description, "Tags" : tags, "EnvironmentVariables" : env})
                
        
            
        for i in resource_names:
            # Load data from the second input JSON file
            with open(input_file2, 'r') as f2:
                data2 = json.load(f2) 
            
            data2["ResourceName"] = i["ResourceName"]
            data2["Description"] = i["Description"]
            data2["Tags"] = i["Tags"]
            data2["EnvironmentVariables"] = i["EnvironmentVariables"]

            with open(i["ResourceName"] + ".json", 'w') as out_f:
                json.dump( data2, out_f, indent=4)
            print(f"New JSON file {i['ResourceName']}.json created successfully.")
        
        # Write the data from the second input JSON file to the output JSON file
        # with open(output_file, 'w') as out_f:
        #     json.dump(data2, out_f, indent=4)
        
        
    
    except FileNotFoundError:
        print("One or both input files not found.")
    except json.JSONDecodeError:
        print("Error decoding JSON data from the input file.")

# Provide the paths of the input JSON files and the output JSON file
input_json_file1 = 'example.json'
input_json_file2 = 'sg_payload.json'


create_new_json(input_json_file1,input_json_file2)