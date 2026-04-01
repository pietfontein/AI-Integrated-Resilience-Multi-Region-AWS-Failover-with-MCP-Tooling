#!/bin/bash
# userdata.sh — Minimal bootstrap for application nodes
# Rendered via templatefile() — variables injected by Terraform

set -euo pipefail

REGION_LABEL="${region_label}"
ENVIRONMENT="${environment}"

# Update and install application runtime
dnf update -y
dnf install -y python3 python3-pip

# Health check endpoint — returns 200 for ALB probes
cat > /opt/app/server.py << 'APP'
import http.server, json, socket

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            body = json.dumps({
                "status": "healthy",
                "region": "REGION_LABEL",
                "host": socket.gethostname()
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args): pass  # Suppress default logging

http.server.HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
APP

sed -i "s/REGION_LABEL/$REGION_LABEL/" /opt/app/server.py
python3 /opt/app/server.py &
