# Story 963: disposable setup fixture

This development-only fixture simulates providers at the provisioning runner's verification/execution boundary. It uses the real console, runner, persisted step records, broadcasts and error handling. It does not exercise provider HTTP clients, SSH, real infrastructure or provider credentials. No real accounts or domain purchases are required.

## Create a fresh fixture

Start this copy with `ensure_app_running`; use its returned origin. Sign in as the seeded `qa@codemyspec.local` user and select QA Account at `/app/accounts/picker`. The seed credentials are `qa-dev-sign-in`.

POST JSON to `/dev/provisioning-fixtures` with `email` and `password`. The response contains `project_id`, `account_id`, `console_path`, and `simulated: true`. Each call creates a new project with an untouched plan. Open the returned console path using the normal authenticated browser. Wait for `[data-phx-main].phx-connected` before clicking Run.

Example on this copy:

```sh
curl -sS -X POST http://127.0.0.1:63664/dev/provisioning-fixtures -H 'Content-Type: application/json' -d '{"email":"qa@codemyspec.local","password":"qa-dev-sign-in"}'
```

## Inspect and control the simulated provider

All requests below are POST JSON and require the same email/password. They authorize against the user's selected account. Ordinary projects cannot be controlled.

- `/dev/provisioning-fixtures/PROJECT_ID/inspect`: returns current simulated resources, ordered events and held requests. Reading this endpoint does not verify or provision anything.
- `/dev/provisioning-fixtures/PROJECT_ID/control`: also accepts `step`, `action`, and optional `environment`. Match the console step's environment exactly; omit it for project-wide server/domain steps.

| Action | Effect |
| --- | --- |
| hold | Hold subsequent execution until release; set before clicking Run. |
| release | Finish the held execution successfully. Release within 120 seconds. |
| refuse | Subsequent execution returns the simulated provider's permission error verbatim. |
| allow | Remove refusal; domain returns to registration pause by default. |
| delete | Remove only the simulated provider resource, retaining the app's recorded step state. |
| register | Create the simulated external resource so verification can find it. |

For refusal/hold scenarios use an absent resource, since verification of an existing resource skips execution. The provider inventory is keyed by step and environment and is independent of the app's persisted step record.

## Browser re-test

1. Create a fresh project. Open its console and inspect the untouched checklist. Compare the provider inspection endpoint before/after opening: no verify/execute events should appear.
2. Set `server/hold`, open `/console/resources/servers`, and click the server Run button. Observe running, inspect the held request, then set `server/release`. Observe done on the same page without reload.
3. Run server again. Inventory must retain one resource with the same identifier; only a verify event is added.
4. Set `server/delete`. The persisted page still says done. Run again and verify one provider resource with a new identifier and a new execute event.
5. Open `/console/resources/dns_domain`. Run domain twice without `register`: both attempts remain paused with instructions; the event history proves both requests executed.
6. Set `domain/refuse`, run domain and inspect errored state, attempted action, and `QA provider refused: token lacks permission to create this resource`. Inspect the normal agent/escalation surface when certifying criterion 568; the fixture does not create a fake agent session.
7. Set `domain/allow`, then `domain/register`, and retry. It should complete; DNS/TLS remain untouched. Email can similarly be refused then allowed to verify isolated retry under `/console/resources/mail`.

Fixtures last for the app process lifetime. After restart, create a new fixture; old marked fixture projects fail closed rather than using real providers. The stored project rows remain available for evidence. Controls simulate one resource per step/environment and do not model associated infrastructure within real providers.

## Dedicated agent fixture for criterion 568

On the local development server, create a fresh provisioning fixture as above. POST the same email/password to `/dev/provisioning-fixtures/PROJECT_ID/prepare-agent`. This returns `working_copy_id`, `root`, and `runtime_path`. Preparation is allowed once per fresh fixture and only for a loopback HTTP server.

From this CodeMySpec checkout, run the following in a separate terminal and keep it running:

```sh
MIX_ENV=harness mix run --no-start priv/repo/qa_963_harness.exs /RETURNED/runtime.json
```

The bootstrap runs a real harness with a dedicated device identity, state directory and dynamically assigned loopback port. The runtime file contains a one-hour OAuth token for the authenticated QA user, stored with mode 0600 inside a mode 0700 directory. It is not returned in the API response. Do not print, copy into evidence, or commit that file. This uses existing OAuth authentication; it does not change the deploy-key exchange used by real copies.

Once the fixture working copy is connected, POST email/password plus `working_copy_id` to `/dev/provisioning-fixtures/PROJECT_ID/start-agent`. It starts a main Alloy agent using the existing local `claude-code` provider and enables continuous mode for that agent. The machine must already have a working Claude CLI login. The response names the agent; verify its running/present state in the normal agent UI. An unsuccessful start is not delivery evidence.

Refuse an absent simulated provider resource, then click Run in the console. Open this project's agent conversation and record the exact provider error, attempted action, and a subsequent agent response. A queued message or console escalation alone does not pass criterion 568. Do not authorize real infrastructure work for this disposable fixture.

After the pass, switch this fixture agent off through the normal UI and stop its dedicated harness with Ctrl-C. Preserve the project and conversation as evidence. If the token expires or the app restarts, create a fresh fixture. Do not restart or reconfigure the shared harness.

## Agent delivery prerequisites

The simulator creates provider state, not an agent or a connected working copy. To verify criterion 568 through a live agent, the fixture project needs its own designated main working copy, a connected model provider, and a present main agent with continuous mode enabled. Use the normal project onboarding and agent controls for these prerequisites. Never attach another project's agent to the fixture.

An errored provisioning step publishes its persisted failure to Agents. The repair message names the project, step, environment, attempted action and verbatim provider error. Confirm delivery in the project's agent conversation; console escalation markup alone is insufficient evidence. Successful and paused steps do not request repair.

Existing agent wake rules remain in force: a non-continuous, off or unavailable agent is not evidence of successful delivery. Missing startup prerequisites are logged and leave the original provider failure intact. For an eligible continuous main agent that is still becoming ready, the message remains in the durable mailbox until presence permits delivery. The transport rechecks off and retired state before sending. Starting an agent does not enable continuous mode automatically.

## Working-agent fixture verification, 2026-10-13

Live implementation check on port 63664: project `3190ae3b-678b-425a-91ef-89f17bf2936e`, working copy `9bde954a-755a-44e6-9d49-88c9e4424fed`, agent `28cef137-a74b-4c1f-8b1d-d0b1ffdcc4e7` (candid-ember). The dedicated harness joined, the agent started with status running, and a domain refusal triggered through the console reached its conversation with the exact provider error and attempted action. The agent responded that it was investigating the domain failure and called diagnostic tools. Screenshot: `/tmp/qa963-live-agent-refusal.png`. The agent was then turned off through the normal UI. This is implementation evidence; independent story QA must create a fresh fixture and record its own outcome.

## Implementation verification, 2026-10-13

- `MIX_ENV=test mix test test/code_my_spec/provisioning/qa_fixture_test.exs`: 7 tests, 0 failures.
- `MIX_ENV=test mix test test/code_my_spec_web/controllers/dev_provisioning_fixture_controller_test.exs`: 3 tests, 0 failures.
- `MIX_ENV=test mix spex test/spex/963_setup_runs_as_a_routine_i_can_watch`: 9 tests, 0 failures.
- Live browser on port 63664, fixture `96f868c0-7a77-420f-8450-3bb230f6c88f`: server running -> done on one mounted page; rerun retained qa-1 with no second execution; simulated deletion followed by Run rebuilt qa-2; domain ran twice and stayed paused; refusal surfaced verbatim with attempted action. This fixture is consumed; QA should create a fresh one. These are implementation checks, not the independent shared QA certification.
