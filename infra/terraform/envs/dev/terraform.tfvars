# Committed on purpose (FR-6): environments differ only through this file. No account ID here;
# aws_account_id comes from TF_VAR_aws_account_id (CI) or a gitignored *.auto.tfvars.
aws_region = "ap-southeast-1"
prefix     = "sis"
env        = "dev"
azs        = ["ap-southeast-1a", "ap-southeast-1b"]
vpc_cidr   = "10.40.0.0/16"

# Placeholder until Phase 4 (ADR 0004, E13): the Docker official image on ECR Public, pinned by index digest,
# serving /health on 8080 from memory (writes nothing to disk) as UID 10001 with a read-only root. Phase 4 removes container_command.
container_image   = "public.ecr.aws/docker/library/python:3.13-slim@sha256:d98cc29d3266e535dd9da1099688d9cb3ca4753813571e071763d17725460962"
container_command = ["python", "-c", "from http.server import*\nclass H(BaseHTTPRequestHandler):\n def do_GET(s):\n  k=s.path in('/','/health');s.send_response(200 if k else 404);s.end_headers();k and s.wfile.write(b'ok')\n def log_message(s,f,*a):print(f%a,flush=True)\nHTTPServer(('0.0.0.0',8080),H).serve_forever()"]

desired_count      = 1
task_cpu           = 256
task_memory        = 512
log_retention_days = 7
