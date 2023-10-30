
# resource "terraform_data" "convert_hcl_to_json" {
#   count = var.convertHCLVarsToJSON ? 1 : 0
#   provisioner "local-exec" {
#     command     = "import sys, subprocess\nsubprocess.check_call([sys.executable, '-m', 'pip', 'install', 'pyhcl'])\nimport hcl\nl = 'sjsd=4, ddd=3'\nobj = hcl.loads(l)\nprint(obj)"
#     interpreter = ["python3", "-c"]
#   }
# }


# data "external" "docker_token" {
#   program = ["python3", "-c", "import sys, json, subprocess\nsubprocess.check_call([sys.executable, '-m', 'pip', 'install', 'pyhcl'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\nimport hcl\nl = 'sjsd=dd, ddd=ddd'\nobj = hcl.loads(l)\nprint(json.dumps(obj))"]
# }

# import sys, json, subprocess
# subprocess.check_call([sys.executable, '-m', 'pip', 'install', 'pyhcl'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
# import hcl
# l = 'sjsd=4, ddd=3'
# obj = hcl.loads(l)
# json.dumps(obj)