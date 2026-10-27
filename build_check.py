#!/usr/bin/env python3
"""Dispatch MetalCAD's build-ipa workflow and/or report run status."""
import json, sys, urllib.request, urllib.error
sys.path.insert(0, "/opt/hatch/skills/skill-creator/bin")
from dynamic_credentials import add_surrogate_to_request, read_json_response

API = "https://api.github.com"
OWNER, REPO = "a-user-of-python", "metalcad"

def api(method, path, data=None):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(API + path, data=body, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if body: req.add_header("Content-Type", "application/json")
    add_surrogate_to_request(req, "custom.github", allowed_hosts=["api.github.com"])
    if method == "POST" and data is None:
        try:
            urllib.request.urlopen(req); return {"status": "ok"}
        except urllib.error.HTTPError as e:
            return {"status": f"HTTP {e.code}"}
    return read_json_response(urllib.request.urlopen(req))

cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
if cmd == "dispatch":
    print(api("POST", f"/repos/{OWNER}/{REPO}/actions/workflows/build-ipa.yml/dispatches",
              {"ref": "main"}))
elif cmd == "status":
    runs = api("GET", f"/repos/{OWNER}/{REPO}/actions/runs?per_page=5")
    for r in runs.get("workflow_runs", []):
        print(r["id"], r["name"], r["status"], r.get("conclusion"), r["created_at"], r["html_url"])
elif cmd == "jobs":
    run_id = sys.argv[2]
    jobs = api("GET", f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}/jobs")
    for j in jobs.get("jobs", []):
        print(j["name"], j["status"], j.get("conclusion"))
        for s in j.get("steps", []):
            print("   ", s["name"], s["status"], s.get("conclusion"))
elif cmd == "artifacts":
    run_id = sys.argv[2]
    arts = api("GET", f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}/artifacts")
    for a in arts.get("artifacts", []):
        print(a["id"], a["name"], a["size_in_bytes"])
