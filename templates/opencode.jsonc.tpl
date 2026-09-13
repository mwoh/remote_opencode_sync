{
  // Project-level opencode config for the cross-device workflow.
  // The session-sync plugin (installed globally) does the automatic sync;
  // these commands are manual fallbacks for explicit control / edge cases.
  "$schema": "https://opencode.ai/config.json",

  "command": {
    "resume": {
      "description": "Pull latest, reconcile any abandoned session, and orient from CONTINUE.md",
      "agent": "build",
      "prompt": "Run the session-start sync ritual: check git status, git pull --rebase, read CONTINUE.md, auto-reconcile any open session from another machine (write LAST SESSION, mark its log END, commit, push), then summarize where the project stands and the next steps."
    },
    "handoff": {
      "description": "Finalize the current session: close session log, refresh CONTINUE.md, commit, push",
      "agent": "build",
      "prompt": "Finalize this session: append a summary to today's session-log file and mark it END, refresh the CONTINUE.md LAST SESSION block, commit everything with a meaningful message, and push. Report the final commit."
    },
    "sync": {
      "description": "Commit and push any pending changes now",
      "agent": "build",
      "prompt": "Commit and push any pending changes with a meaningful message, refresh CONTINUE.md and the session log if changed, and report the resulting git log entry."
    }
  }
}