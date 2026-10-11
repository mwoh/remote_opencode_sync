{
  // Project-level opencode config for the cross-device workflow.
  // The session-sync plugin (installed globally) does the automatic sync;
  // these commands are manual fallbacks for explicit control / edge cases.
  "$schema": "https://opencode.ai/config.json",
  "model": "@@MODEL@@",

  "$comment": "The command block below is roe-managed: `roe upgrade` may refresh it to the current toolkit. Edit it only if you accept that it will be replaced on upgrade.",
  "command": {
    "resume": {
      "description": "Pull latest, reconcile any abandoned session, and orient from CONTINUE.md",
      "agent": "build",
      "template": "Run the session-start sync ritual: check git status, git pull --rebase, read CONTINUE.md, auto-reconcile any open session from another machine (write LAST SESSION, mark its log END, commit, push), then summarize where the project stands and the next steps."
    },
    "handoff": {
      "description": "Finalize the current session: close session log, refresh CONTINUE.md, back up history, commit, push",
      "agent": "build",
      "template": "Finalize this session: append a summary to today's session-log file and mark it END, refresh the CONTINUE.md LAST SESSION block, run `roe history backup` and note the archive path it reports (this machine's conversation history is archived under opencode-history/<host>/ and travels with the repo), then commit everything with a meaningful message, and push. Report the final commit."
    },
    "sync": {
      "description": "Check history freshness, then commit and push any pending changes now",
      "agent": "build",
      "template": "First run `roe history status` to check this machine's session-history archive. If it exits non-zero (report is 'missing' or 'stale'), warn the user that this machine's session history is not archived (or is over 7 days old) and tell them to run `roe history backup`. Then commit and push any pending changes with a meaningful message, refresh CONTINUE.md and the session log if changed, and report the resulting git log entry."
    }
  }
}