#!/usr/bin/env python3

import argparse
import json
import sys
import urllib.request


def rpc_call(port, method, params=None):
  url = f"http://127.0.0.1:{port}/rpc"
  payload = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": method
  }
  if params is not None:
    payload["params"] = params
  data = json.dumps(payload).encode("utf-8")
  req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
  try:
    with urllib.request.urlopen(req, timeout=15) as resp:
      body = resp.read().decode("utf-8")
  except Exception as exc:
    return {"error": {"message": str(exc)}}
  try:
    return json.loads(body)
  except json.JSONDecodeError:
    return {"error": {"message": f"Invalid JSON response: {body[:200]}"}}


def fail(message):
  print(f"FAIL: {message}")
  sys.exit(1)


def main():
  parser = argparse.ArgumentParser(description="Automate MCP test plan validation.")
  parser.add_argument("--port", type=int, default=8765)
  parser.add_argument("--working-directory", required=True)
  parser.add_argument("--template-name", default="MCP Harness")
  parser.add_argument("--prompt", default="Reply with a short confirmation. Do not edit any files.")
  parser.add_argument("--enable-review-loop", action="store_true")
  parser.add_argument("--skip-run", action="store_true", help="Skip chains.run test")
  args = parser.parse_args()

  print("MCP Test Plan: tools/list")
  tools = rpc_call(args.port, "tools/list")
  if "error" in tools:
    fail(f"tools/list error: {tools['error']}")
  tool_names = [tool.get("name") for tool in tools.get("result", {}).get("tools", [])]
  if "templates.list" not in tool_names or "chains.run" not in tool_names:
    fail("tools/list missing templates.list or chains.run")
  print("PASS: tools/list")

  print("MCP Test Plan: templates.list")
  templates = rpc_call(args.port, "tools/call", {"name": "templates.list", "arguments": {}})
  if "error" in templates:
    fail(f"templates.list error: {templates['error']}")
  template_list = templates.get("result", {}).get("templates", [])
  template_names = [t.get("name") for t in template_list]
  if args.template_name not in template_names:
    fail(f"Template not found: {args.template_name}")
  print("PASS: templates.list")

  print("MCP Test Plan: chains.run missing prompt")
  missing_prompt = rpc_call(args.port, "tools/call", {"name": "chains.run", "arguments": {}})
  if "error" not in missing_prompt:
    fail("Expected error for missing prompt, but got success")
  error_code = missing_prompt["error"].get("code")
  if error_code not in (-32602, -32000, -32001):
    fail(f"Unexpected error code for missing prompt: {error_code}")
  print("PASS: chains.run missing prompt")

  if args.skip_run:
    print("SKIP: chains.run success test")
    return

  print("MCP Test Plan: chains.run success")
  run_args = {
    "templateName": args.template_name,
    "prompt": args.prompt,
    "workingDirectory": args.working_directory,
    "enableReviewLoop": args.enable_review_loop
  }
  run = rpc_call(args.port, "tools/call", {"name": "chains.run", "arguments": run_args})
  if "error" in run:
    fail(f"chains.run error: {run['error']}")
  result = run.get("result", {})
  if result.get("success") is not True:
    fail("chains.run did not succeed")
  chain_state = result.get("chain", {}).get("state")
  if chain_state not in ("Complete", "Running", "Review Loop 1"):
    fail(f"Unexpected chain state: {chain_state}")
  print("PASS: chains.run success")

  print("All MCP test plan checks passed.")


if __name__ == "__main__":
  main()
