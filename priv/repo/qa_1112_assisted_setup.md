# Story 1112: assisted desktop setup fixture

This fixture configures the disposable desktop user's main agent to use the harness machine's existing Claude CLI login. It uses the normal cockpit, harness, agent transport and setup-help button. It does not create a fake running agent, copy provider credentials, or test the onboarding interview (story 1064).

## Prepare

1. Use the disposable desktop environment from `qa_1112_bootstrap.md`. Name its database `qa1112_<unique_suffix>` or `qa_1112_<unique_suffix>`. Use a separate disposable project directory and isolated setup-results storage. Keep the real development database and checkout out of this fixture.
2. The desktop process must inherit a PATH containing the authenticated `claude` executable. A successful prerequisite version check does not prove authentication. Use the operator's existing local login; do not copy OAuth tokens into the database.
3. Run the desktop prerequisite checks, create or link the disposable project, and wait for Project connected. Finish setup. Record the project UUID from the cockpit URL. This establishes the normal main working copy and harness connection.
4. Against exactly that database, run the database-only seed from this checkout, using the same OS user as the desktop:

```sh
MIX_ENV=desktop DATABASE_URL=ecto://localhost/qa1112_assisted_example mix cms.seed priv/repo/qa_1112_assisted_setup_seed.exs qa1112_assisted_example PROJECT_UUID
```

Replace the example database and project UUID with this run's values. The seed refuses other database naming patterns, mismatched databases, a project other than the desktop user's selected project, a missing main working copy, or a conflicting existing main-agent model setting. It is safe to repeat for the same fixture. Model settings are user-scoped; the disposable database is the isolation boundary.

## Exercise real assistance

1. Reload the project's `/app/projects/PROJECT_UUID/agent-conversation` cockpit. Let its normal startup path launch the main agent. Confirm it becomes available; a stored model setting or agent row alone is insufficient. If launch or authentication fails, record the actual error and stop this provider-dependent check.
2. Open `/app` in the same desktop. The setup results should remain readable. The help control should now be available because the main agent is present.
3. Record the setup results file contents and timestamps before requesting help. Request help through the setup page, then follow the conversation link. Verify the delivered user message contains the recorded prerequisite results and that the real agent replies about those results.
4. Confirm requesting help and reopening the page did not rerun completed checks or overwrite their outcomes. Record the after-state and compare it with the before-state.
5. For the missing-prerequisite assistance clause, repeat in an isolated machine/VM with a reproducible failed prerequisite while retaining a reachable main agent. Do not uninstall software or stop shared services to manufacture a failure. Record the failed command, exit status, captured output, delivered help message and agent reply. A run containing only successful checks does not certify assistance with a missing prerequisite.

## Evidence and lifecycle

Record the application revision, disposable database name, project/copy/agent identifiers, provider, screenshot of setup results and help control, conversation message/reply, and before/after results evidence. Do not include authentication tokens. Configuration success is not a QA pass; shared QA must observe the actual delivery and response.

The seed changes only the disposable desktop user's main model setting. It does not launch agents, alter setup results, or modify project files. Stop the disposable desktop and its agents after testing; retain the database, directory and results while evidence is needed. Use a new disposable database and directory for a fresh premise. No cleanup command should target the shared development database or existing checkout.
