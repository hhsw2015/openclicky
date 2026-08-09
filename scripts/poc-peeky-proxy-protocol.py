#!/usr/bin/env python3
"""
POC: Peeky aegis-proxy protocol - free Claude Agent CLI.

Proves the proxy has NO client verification beyond a UUID header.
Implements a full agent loop with local tool execution:
  - read_file: read a file from disk
  - write_file: write content to a file
  - edit_file: replace text in a file
  - bash: execute shell commands
  - list_dir: list directory contents
  - grep: search file contents

Usage:
    python3 scripts/poc-peeky-proxy-protocol.py              # run protocol tests
    python3 scripts/poc-peeky-proxy-protocol.py --agent      # interactive agent CLI
    python3 scripts/poc-peeky-proxy-protocol.py --agent -m "fix the bug in main.py"

No Peeky app needed. No API keys needed.
"""

import json
import os
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

try:
    import requests
except ImportError:
    print("pip install requests")
    sys.exit(1)


PROXY_URL = os.environ.get("AEGIS_PROXY_BASE", "").rstrip("/") + "/v1/anthropic/messages"
ANTHROPIC_VERSION = "2023-06-01"
MAX_AGENT_STEPS = 15


# ─────────────────────────────────────────────────────────────────────────────
# SSE Parser
# ─────────────────────────────────────────────────────────────────────────────


def parse_sse_stream(resp):
    """Parse Anthropic SSE stream. Yields (type, data) tuples.
    Types: 'text', 'tool_use_start', 'tool_input_delta', 'tool_use_end', 'done'
    """
    buffer = ""
    for chunk in resp.iter_content(chunk_size=None):
        if not chunk:
            continue
        buffer += chunk.decode("utf-8", errors="replace")
        while "\n\n" in buffer:
            frame, buffer = buffer.split("\n\n", 1)
            for line in frame.split("\n"):
                if not line.startswith("data: "):
                    continue
                data = line[6:]
                if data == "[DONE]":
                    yield ("done", None)
                    return
                try:
                    event = json.loads(data)
                except json.JSONDecodeError:
                    continue
                etype = event.get("type", "")
                if etype == "content_block_start":
                    block = event.get("content_block", {})
                    if block.get("type") == "tool_use":
                        yield ("tool_use_start", {
                            "id": block.get("id", ""),
                            "name": block.get("name", ""),
                        })
                    elif block.get("type") == "text":
                        pass
                elif etype == "content_block_delta":
                    delta = event.get("delta", {})
                    if delta.get("type") == "text_delta":
                        yield ("text", delta.get("text", ""))
                    elif delta.get("type") == "input_json_delta":
                        yield ("tool_input_delta", delta.get("partial_json", ""))
                elif etype == "content_block_stop":
                    yield ("tool_use_end", None)
                elif etype == "message_stop":
                    yield ("done", None)
                    return
                elif etype == "error":
                    yield ("error", event)
                    return


def collect_response(resp):
    """Collect full response: text blocks and tool_use blocks."""
    text_parts = []
    tool_calls = []
    current_tool = None
    tool_json_buf = ""

    for etype, data in parse_sse_stream(resp):
        if etype == "text":
            text_parts.append(data)
            print(data, end="", flush=True)
        elif etype == "tool_use_start":
            current_tool = data
            tool_json_buf = ""
        elif etype == "tool_input_delta":
            tool_json_buf += data
        elif etype == "tool_use_end":
            if current_tool:
                try:
                    input_obj = json.loads(tool_json_buf) if tool_json_buf else {}
                except json.JSONDecodeError:
                    input_obj = {"_raw": tool_json_buf}
                tool_calls.append({
                    "id": current_tool["id"],
                    "name": current_tool["name"],
                    "input": input_obj,
                })
                current_tool = None
        elif etype == "done":
            break
        elif etype == "error":
            text_parts.append(f"\n[ERROR: {data}]")
            break

    return "".join(text_parts), tool_calls


# ─────────────────────────────────────────────────────────────────────────────
# Local Tool Definitions & Execution
# ─────────────────────────────────────────────────────────────────────────────

TOOLS = [
    {
        "name": "bash",
        "description": "Execute a shell command and return stdout+stderr. Use for running tests, git, builds, etc.",
        "input_schema": {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The shell command to execute",
                }
            },
            "required": ["command"],
        },
    },
    {
        "name": "read_file",
        "description": "Read the contents of a file. Returns the full text content.",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Absolute or relative file path to read",
                }
            },
            "required": ["path"],
        },
    },
    {
        "name": "write_file",
        "description": "Write content to a file. Creates parent directories if needed. Overwrites existing content.",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "File path to write to",
                },
                "content": {
                    "type": "string",
                    "description": "Content to write",
                },
            },
            "required": ["path", "content"],
        },
    },
    {
        "name": "edit_file",
        "description": "Replace exact text in a file. The old_text must match exactly (including whitespace).",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "File path to edit",
                },
                "old_text": {
                    "type": "string",
                    "description": "Exact text to find and replace",
                },
                "new_text": {
                    "type": "string",
                    "description": "Replacement text",
                },
            },
            "required": ["path", "old_text", "new_text"],
        },
    },
    {
        "name": "list_dir",
        "description": "List files and directories at a path. Returns names with / suffix for directories.",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Directory path to list (default: current directory)",
                }
            },
            "required": [],
        },
    },
    {
        "name": "grep",
        "description": "Search for a pattern in files. Returns matching lines with file:line: prefix.",
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "Search pattern (regex)",
                },
                "path": {
                    "type": "string",
                    "description": "File or directory to search in (default: current directory)",
                },
                "include": {
                    "type": "string",
                    "description": "File glob pattern, e.g. '*.py' or '*.ts'",
                },
            },
            "required": ["pattern"],
        },
    },
]


def execute_tool(name: str, input_obj: dict) -> str:
    """Execute a local tool and return the result string."""
    try:
        if name == "bash":
            cmd = input_obj.get("command", "")
            print(f"\n  [exec] $ {cmd}")
            result = subprocess.run(
                cmd, shell=True, capture_output=True, text=True, timeout=30
            )
            output = result.stdout
            if result.stderr:
                output += f"\n[stderr]\n{result.stderr}"
            if result.returncode != 0:
                output += f"\n[exit code: {result.returncode}]"
            return output[:10000] or "(no output)"

        elif name == "read_file":
            path = input_obj.get("path", "")
            print(f"\n  [read] {path}")
            content = Path(path).read_text(encoding="utf-8", errors="replace")
            if len(content) > 15000:
                return content[:15000] + f"\n\n[truncated, {len(content)} total chars]"
            return content

        elif name == "write_file":
            path = input_obj.get("path", "")
            content = input_obj.get("content", "")
            print(f"\n  [write] {path} ({len(content)} chars)")
            p = Path(path)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content, encoding="utf-8")
            return f"Written {len(content)} chars to {path}"

        elif name == "edit_file":
            path = input_obj.get("path", "")
            old_text = input_obj.get("old_text", "")
            new_text = input_obj.get("new_text", "")
            print(f"\n  [edit] {path}")
            content = Path(path).read_text(encoding="utf-8")
            if old_text not in content:
                return f"ERROR: old_text not found in {path}"
            count = content.count(old_text)
            content = content.replace(old_text, new_text, 1)
            Path(path).write_text(content, encoding="utf-8")
            return f"Replaced 1 of {count} occurrence(s) in {path}"

        elif name == "list_dir":
            path = input_obj.get("path", ".")
            print(f"\n  [ls] {path}")
            entries = []
            for item in sorted(Path(path).iterdir()):
                name_str = item.name + ("/" if item.is_dir() else "")
                entries.append(name_str)
            return "\n".join(entries[:200])

        elif name == "grep":
            pattern = input_obj.get("pattern", "")
            path = input_obj.get("path", ".")
            include = input_obj.get("include", "")
            print(f"\n  [grep] '{pattern}' in {path}")
            cmd = ["grep", "-rn", "--color=never"]
            if include:
                cmd += [f"--include={include}"]
            cmd += [pattern, path]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            output = result.stdout
            if len(output) > 8000:
                lines = output.split("\n")
                output = "\n".join(lines[:50]) + f"\n\n[truncated, {len(lines)} total matches]"
            return output or "(no matches)"

        else:
            return f"Unknown tool: {name}"

    except FileNotFoundError as e:
        return f"File not found: {e}"
    except PermissionError as e:
        return f"Permission denied: {e}"
    except subprocess.TimeoutExpired:
        return "Command timed out (30s limit)"
    except Exception as e:
        return f"Error: {type(e).__name__}: {e}"


# ─────────────────────────────────────────────────────────────────────────────
# Proxy Client
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class ProxyClient:
    device_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    model: str = "claude-sonnet-4-20250514"

    def _headers(self):
        return {
            "x-peeky-device-id": self.device_id,
            "anthropic-version": ANTHROPIC_VERSION,
            "content-type": "application/json",
        }

    def _post(self, body: dict) -> requests.Response:
        return requests.post(
            PROXY_URL,
            headers=self._headers(),
            json=body,
            stream=True,
            timeout=120,
        )

    def reset_quota(self):
        self.device_id = str(uuid.uuid4())
        return self.device_id

    def agent_turn(self, messages: list, system: str) -> tuple:
        """One agent turn: send messages, get text + tool_calls back."""
        body = {
            "model": self.model,
            "max_tokens": 4096,
            "stream": True,
            "system": system,
            "tools": TOOLS,
            "messages": messages,
        }
        resp = self._post(body)
        if resp.status_code == 429:
            print("\n[quota exhausted, rotating device_id...]")
            self.reset_quota()
            resp = self._post(body)
        if resp.status_code != 200:
            error_body = resp.text[:500]
            return f"[API error {resp.status_code}: {error_body}]", []
        return collect_response(resp)

    def run_agent_loop(self, user_prompt: str, system: str = None):
        """Full agent loop: send prompt, execute tools, repeat until done."""
        if system is None:
            cwd = os.getcwd()
            system = (
                f"You are a coding agent. You help the user with software engineering tasks.\n"
                f"Working directory: {cwd}\n"
                f"You have tools to read/write/edit files, run bash commands, list directories, and grep.\n"
                f"Use tools to accomplish the user's request. Be concise in your responses.\n"
                f"When done, respond with text explaining what you did."
            )

        messages = [{"role": "user", "content": user_prompt}]

        for step in range(MAX_AGENT_STEPS):
            print(f"\n--- Step {step + 1}/{MAX_AGENT_STEPS} ---")
            text, tool_calls = self.agent_turn(messages, system)

            if not tool_calls:
                if text:
                    print()
                print(f"\n[Agent finished after {step + 1} step(s)]")
                return text

            # Build assistant message content
            assistant_content = []
            if text:
                assistant_content.append({"type": "text", "text": text})
            for tc in tool_calls:
                assistant_content.append({
                    "type": "tool_use",
                    "id": tc["id"],
                    "name": tc["name"],
                    "input": tc["input"],
                })
            messages.append({"role": "assistant", "content": assistant_content})

            # Execute tools and build tool_result message
            tool_results = []
            for tc in tool_calls:
                result = execute_tool(tc["name"], tc["input"])
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": tc["id"],
                    "content": result,
                })
            messages.append({"role": "user", "content": tool_results})

        print(f"\n[Agent hit max steps ({MAX_AGENT_STEPS})]")
        return text


# ─────────────────────────────────────────────────────────────────────────────
# Protocol Tests
# ─────────────────────────────────────────────────────────────────────────────


def test_classify(client: ProxyClient):
    print("\n[TEST 1] Classify intent")
    print(f"  Device ID: {client.device_id}")
    tests = [
        ("click the blue button", "find_action"),
        ("play some jazz", "integration"),
        ("what is the meaning of life", "chat"),
        ("remember my name is Alice", "memory"),
        ("open youtube search for cats and play the first one", "agent"),
    ]
    all_ok = True
    for transcript, expected in tests:
        body = {
            "model": "claude-haiku-4-5",
            "max_tokens": 80,
            "stream": True,
            "system": [{"type": "text", "text": (
                "Classify into: find_action, integration, chat, memory, agent. "
                "Call the classify tool."
            ), "cache_control": {"type": "ephemeral"}}],
            "tools": [{"name": "classify", "description": "Emit category.",
                       "input_schema": {"type": "object", "properties": {
                           "category": {"type": "string",
                                        "enum": ["find_action", "integration", "chat", "memory", "agent"]}},
                           "required": ["category"]}}],
            "tool_choice": {"type": "tool", "name": "classify"},
            "messages": [{"role": "user", "content": transcript}],
        }
        t0 = time.time()
        resp = client._post(body)
        if resp.status_code != 200:
            print(f"  ERROR {resp.status_code}")
            all_ok = False
            continue
        _, tools = collect_response(resp)
        elapsed = time.time() - t0
        result = tools[0]["input"].get("category") if tools else None
        ok = result == expected
        if not ok:
            all_ok = False
        print(f"  '{transcript[:40]}' -> {result} [{elapsed:.1f}s] {'OK' if ok else 'MISMATCH'}")
    return all_ok


def test_chat(client: ProxyClient):
    print("\n[TEST 2] Chat path")
    body = {
        "model": "claude-haiku-4-5",
        "max_tokens": 50,
        "stream": True,
        "system": "Answer in one word only.",
        "messages": [{"role": "user", "content": "What is 2+2?"}],
    }
    t0 = time.time()
    resp = client._post(body)
    if resp.status_code != 200:
        print(f"  ERROR {resp.status_code}: {resp.text[:100]}")
        return False
    text, _ = collect_response(resp)
    elapsed = time.time() - t0
    print(f"\n  Response: [{text.strip()}] [{elapsed:.1f}s]")
    return bool(text.strip())


def test_agent_tool(client: ProxyClient):
    print("\n[TEST 3] Agent loop (local tool execution)")
    body = {
        "model": "claude-haiku-4-5",
        "max_tokens": 200,
        "stream": True,
        "system": "You have a bash tool. Use it to answer the user.",
        "tools": [TOOLS[0]],  # bash only
        "messages": [{"role": "user", "content": "What is the current date? Use the bash tool to run `date`."}],
    }
    t0 = time.time()
    resp = client._post(body)
    if resp.status_code != 200:
        print(f"  ERROR {resp.status_code}")
        return False
    _, tools = collect_response(resp)
    elapsed = time.time() - t0
    if tools:
        result = execute_tool(tools[0]["name"], tools[0]["input"])
        print(f"\n  Tool: {tools[0]['name']}({tools[0]['input']})")
        print(f"  Result: {result.strip()}")
        print(f"  [{elapsed:.1f}s]")
        return True
    print(f"  No tool call [{elapsed:.1f}s]")
    return False


def test_quota_reset(client: ProxyClient):
    print("\n[TEST 4] Quota reset")
    old_id = client.device_id
    new_id = client.reset_quota()
    print(f"  {old_id} -> {new_id}")
    body = {
        "model": "claude-haiku-4-5",
        "max_tokens": 20,
        "stream": True,
        "messages": [{"role": "user", "content": "Say OK"}],
    }
    resp = client._post(body)
    if resp.status_code != 200:
        print(f"  ERROR {resp.status_code}")
        return False
    text, _ = collect_response(resp)
    print(f"\n  Response: [{text.strip()}]")
    return bool(text.strip())


def run_tests():
    print("=" * 60)
    print("POC: aegis-proxy protocol verification")
    print("=" * 60)
    print("\nNo Peeky app binary. Pure HTTP + UUID.\n")

    client = ProxyClient(model="claude-haiku-4-5")
    print(f"Device ID: {client.device_id}")

    results = [
        ("Classify", test_classify(client)),
        ("Chat", test_chat(client)),
        ("Agent tool", test_agent_tool(client)),
        ("Quota reset", test_quota_reset(client)),
    ]

    print("\n" + "=" * 60)
    for name, passed in results:
        print(f"  [{'PASS' if passed else 'FAIL'}] {name}")
    print("=" * 60)

    all_pass = all(r[1] for r in results)
    if all_pass:
        print("\nAll passed. Proxy has zero client verification.")
        print("Use --agent for interactive Claude Code mode.")
    return 0 if all_pass else 1


# ─────────────────────────────────────────────────────────────────────────────
# Interactive Agent CLI
# ─────────────────────────────────────────────────────────────────────────────


def run_interactive_agent(initial_message=None, model=None):
    print("=" * 60)
    print("  Free Claude Agent CLI (via aegis-proxy)")
    print("=" * 60)

    client = ProxyClient(model=model or "claude-sonnet-4-20250514")
    print(f"  Model: {client.model}")
    print(f"  Device: {client.device_id}")
    print(f"  CWD: {os.getcwd()}")
    print(f"  Commands: /quit /reset /model <name>")
    print("=" * 60)

    if initial_message:
        print(f"\n> {initial_message}")
        client.run_agent_loop(initial_message)

    while True:
        try:
            prompt = input("\n> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nBye.")
            break

        if not prompt:
            continue
        if prompt == "/quit":
            break
        if prompt == "/reset":
            old = client.device_id
            client.reset_quota()
            print(f"  Rotated: {old} -> {client.device_id}")
            continue
        if prompt.startswith("/model "):
            client.model = prompt[7:].strip()
            print(f"  Model set to: {client.model}")
            continue

        client.run_agent_loop(prompt)


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Peeky proxy POC + free Agent CLI")
    parser.add_argument("--agent", action="store_true", help="Interactive agent mode")
    parser.add_argument("-m", "--message", type=str, help="Initial agent message")
    parser.add_argument("--model", type=str, default=None, help="Model to use")
    args = parser.parse_args()

    if args.agent or args.message:
        run_interactive_agent(initial_message=args.message, model=args.model)
        return 0
    else:
        return run_tests()


if __name__ == "__main__":
    sys.exit(main())
