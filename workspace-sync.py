#!/usr/bin/env python3
"""
HuggingClaw Workspace Sync — HuggingFace Hub based backup
Uses huggingface_hub Python library instead of git for more reliable
HF Dataset operations (handles auth, LFS, retries automatically).

Falls back to git-based sync if HF_USERNAME or HF_TOKEN are not set.
"""

import os
import sys
import time
import signal
import subprocess
from pathlib import Path

WORKSPACE = Path("/home/node/.openclaw/workspace")
INTERVAL = int(os.environ.get("SYNC_INTERVAL", "600"))
HF_TOKEN = os.environ.get("HF_TOKEN", "")
HF_USERNAME = os.environ.get("HF_USERNAME", "")
BACKUP_DATASET = os.environ.get("BACKUP_DATASET_NAME", "huggingclaw-backup")
WEBHOOK_URL = os.environ.get("WEBHOOK_URL", "")

running = True

def signal_handler(sig, frame):
    global running
    running = False

signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)


def has_changes():
    """Check if workspace has uncommitted changes (git-based check)."""
    try:
        subprocess.run(["git", "add", "-A"], cwd=WORKSPACE, capture_output=True)
        result = subprocess.run(
            ["git", "diff", "--cached", "--quiet"],
            cwd=WORKSPACE, capture_output=True
        )
        return result.returncode != 0
    except Exception:
        return False

def write_sync_status(status, message=""):
    """Write sync status to file for the health server dashboard."""
    try:
        import json
        data = {
            "status": status,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "message": message
        }
        with open("/tmp/sync-status.json", "w") as f:
            json.dump(data, f)
    except Exception as e:
        print(f"  ⚠️ Could not write sync status: {e}")

def trigger_webhook(event, status, message):
    """Trigger webhook notification."""
    if not WEBHOOK_URL:
        return
    try:
        import urllib.request
        import json
        data = json.dumps({
            "event": event,
            "status": status,
            "message": message,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        }).encode('utf-8')
        req = urllib.request.Request(WEBHOOK_URL, data=data, headers={'Content-Type': 'application/json'})
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f"  ⚠️ Webhook delivery failed: {e}")

def sync_with_hf_hub():
    """Sync workspace using huggingface_hub library."""
    try:
        from huggingface_hub import HfApi, upload_folder

        api = HfApi(token=HF_TOKEN)
        repo_id = f"{HF_USERNAME}/{BACKUP_DATASET}"

        # Ensure dataset exists
        try:
            api.repo_info(repo_id=repo_id, repo_type="dataset")
        except Exception:
            print(f"  📝 Creating dataset {repo_id}...")
            try:
                api.create_repo(repo_id=repo_id, repo_type="dataset", private=True)
                print(f"  ✅ Dataset created: {repo_id}")
            except Exception as e:
                print(f"  ⚠️  Could not create dataset: {e}")
                return False

        # Upload workspace
        upload_folder(
            folder_path=str(WORKSPACE),
            repo_id=repo_id,
            repo_type="dataset",
            token=HF_TOKEN,
            commit_message=f"Auto-sync {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}",
            ignore_patterns=[".git/*", ".git"],
        )
        return True

    except ImportError:
        print("  ⚠️  huggingface_hub not installed, falling back to git")
        return False
    except Exception as e:
        print(f"  ⚠️  HF Hub sync failed: {e}")
        return False


def sync_with_git():
    """Fallback: sync workspace using git."""
    try:
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        subprocess.run(["git", "add", "-A"], cwd=WORKSPACE, capture_output=True)
        subprocess.run(
            ["git", "commit", "-m", f"Auto-sync {ts}"],
            cwd=WORKSPACE, capture_output=True
        )
        result = subprocess.run(
            ["git", "push", "origin", "main"],
            cwd=WORKSPACE, capture_output=True
        )
        return result.returncode == 0
    except Exception:
        return False


def main():
    # Wait for workspace to initialize
    time.sleep(30)

    if not WORKSPACE.exists():
        print("📁 Workspace sync: workspace not found, exiting.")
        return

    use_hf_hub = bool(HF_TOKEN and HF_USERNAME)

    if use_hf_hub:
        print(f"🔄 Workspace sync started (huggingface_hub): every {INTERVAL}s → {HF_USERNAME}/{BACKUP_DATASET}")
    else:
        git_dir = WORKSPACE / ".git"
        if not git_dir.exists():
            print("📁 Workspace sync: no git repo and no HF credentials, skipping.")
            return
        print(f"🔄 Workspace sync started (git): every {INTERVAL}s")

    while running:
        time.sleep(INTERVAL)
        if not running:
            break

        if not has_changes():
            continue

        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        
        write_sync_status("syncing", f"Starting sync at {ts}")

        if use_hf_hub:
            if sync_with_hf_hub():
                print(f"🔄 Workspace sync (hf_hub): pushed changes ({ts})")
                write_sync_status("success", "Successfully pushed to HF Hub")
            else:
                # Fallback to git
                if sync_with_git():
                    print(f"🔄 Workspace sync (git fallback): pushed changes ({ts})")
                    write_sync_status("success", "Successfully pushed via git fallback")
                else:
                    msg = f"Workspace sync: failed ({ts}), will retry"
                    print(f"🔄 {msg}")
                    write_sync_status("error", msg)
                    trigger_webhook("sync", "error", msg)
        else:
            if sync_with_git():
                print(f"🔄 Workspace sync (git): pushed changes ({ts})")
                write_sync_status("success", "Successfully pushed via git")
            else:
                msg = f"Workspace sync: push failed ({ts}), will retry"
                print(f"🔄 {msg}")
                write_sync_status("error", msg)
                trigger_webhook("sync", "error", msg)


if __name__ == "__main__":
    main()
