<!-- appended by remote_opencode_sync when this project already had an AGENTS.md / rules.
     You can edit or remove this block freely. -->
## Cross-Device Workflow Rules

This project is synced across several of the user's machines. Git is the source of truth
for BOTH the code and the progress. Follow these rules without being reminded:

1. **Session start — orient first.** Read `CONTINUE.md` before any work; state what the
   last session did and the NEXT STEPS before proceeding. If the sync plugin is absent,
   run `git pull --rebase` yourself.
2. **Auto-reconcile an abandoned session.** If the newest `session-logs/*.md` from another
   machine is `IN PROGRESS` with no closed `LAST SESSION`, synthesize the handoff into
   `CONTINUE.md`, mark the log `END`, commit, push — then report what you reconstructed.
3. **Commit + push after every completed task.** Message format `type(scope): summary`.
   Never leave unpushed commits at session end.
4. **Keep the tree clean.** Clean working tree at every session boundary; `wip:` commits
   are the plugin's backup, not a substitute for real commits.
5. **Maintain `CONTINUE.md` continuously** — Status, Open decisions, NEXT STEPS.
6. **Session log.** Write to `session-logs/YYYY-MM-DD-<machine>.md`, header
   `... — IN PROGRESS`, close with `... — END`.
7. **Before compaction / session end:** commit + push, write the `LAST SESSION` block,
   mark the log `END`, push once more.
8. **Conflicts.** Prefer `git pull --rebase`; resolve immediately and note in `CONTINUE.md`.
9. **Secrets.** Never commit keys/tokens; use gitignored env files + `.env.example`.
10. **Machine awareness.** On a light machine don't run heavy builds — record them as
    NEXT STEPS for the capable machine.