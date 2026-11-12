#!/usr/bin/env python3
"""Record one live ACP v2 turn of claude-agent-acp on haiku, in a scratch directory: an Edit
whose permission is allowed once, and a background command. Keeps the session updates and
permission requests, without the command lists, which name the user's own skills and agents."""
import json
import os
import select
import subprocess
import tempfile
import time
from pathlib import Path

PROMPT = (
    "Do exactly these two steps and nothing else. 1) Use the Edit tool to replace the word alpha with "
    "beta in notes.txt. 2) Use the Bash tool with run_in_background set to true to run: sleep 3; echo done. "
    "Then reply with one word."
)
# The background command's end arrives after the turn's `idle`.
AFTER_IDLE_S = 15

cwd = tempfile.mkdtemp(prefix="acp-v2-turn-")
Path(cwd, "notes.txt").write_text("alpha line\n")
proc = subprocess.Popen(
    ["claude-agent-acp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    env=dict(os.environ, CLAUDE_AGENT_ACP_PROTOCOL="v2"),
    cwd=cwd,
    text=True,
)
assert proc.stdin and proc.stdout
stdin, stdout = proc.stdin, proc.stdout


def send(msg):
    stdin.write(json.dumps({"jsonrpc": "2.0", **msg}) + "\n")
    stdin.flush()


def request(id, method, params):
    send({"id": id, "method": method, "params": params})


kept = []
session = None
idle_at = None
request(1, "initialize", {
    "protocolVersion": 2, "info": {"name": "fixture", "version": "0"},
    "capabilities": {"auth": {"terminal": {}}, "_meta": {"terminal_output": True}}})
deadline = time.time() + 240
while time.time() < deadline and not (idle_at and time.time() - idle_at > AFTER_IDLE_S):
    if not select.select([stdout], [], [], 1)[0]:
        continue
    line = stdout.readline()
    if not line:
        break
    msg = json.loads(line)
    method, id = msg.get("method"), msg.get("id")
    update = msg.get("params", {}).get("update", {})
    if method == "session/request_permission" or (
        method == "session/update" and update.get("sessionUpdate") != "available_commands_update"
    ):
        kept.append(line)
    if method is None and id == 1:
        request(2, "session/new", {"cwd": cwd, "mcpServers": []})
    elif method is None and id == 2:
        session = msg["result"]["sessionId"]
        request(3, "session/set_config_option",
                {"sessionId": session, "configId": "model", "type": "id", "value": "haiku"})
    elif method is None and id == 3:
        request(4, "session/set_config_option",
                {"sessionId": session, "configId": "mode", "type": "id", "value": "default"})
    elif method is None and id == 4:
        request(5, "session/prompt", {"sessionId": session, "prompt": [{"type": "text", "text": PROMPT}]})
    elif method == "session/request_permission":
        option = next(o for o in msg["params"]["options"] if o["kind"] == "allow_once")
        send({"id": id, "result": {"outcome": {"outcome": "selected", "optionId": option["optionId"]}}})
    elif update.get("sessionUpdate") == "state_update" and update["state"] == "idle":
        idle_at = time.time()
proc.terminate()

Path(__file__).with_suffix("").write_text("".join(kept))
