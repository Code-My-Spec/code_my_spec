# Story 1112: desktop startup without database prerequisites

Issue: b786927d-e422-4a62-9625-cc86a487c4f9.

Use an isolated machine or disposable VM. Do not uninstall or stop the shared development machine's database. Launch the desktop release normally; CMS_BROWSER=1 may be used to inspect the same page in a browser.

1. With Postgres unavailable, launch the app. The window must open before database creation or migration. It should show prerequisite checks and explain that agent assistance needs the database, while manual setup remains available. Opening or refreshing the page must not run checks.
2. Click Check prerequisites. Verify Postgres/pgvector failures and installation guidance remain visible. Inspect the results file named on the page: command output, exit status or executable error, and attempt timestamps must be recorded. Start CodeMySpec must not be available while checks fail.
3. Repeat on a machine with Postgres installed but pgvector absent. The window must still open and the extension check must fail rather than accepting an empty successful SQL query.
4. Install the missing prerequisites using the guidance, then explicitly run checks again. Earlier run files must remain intact. Once all checks pass, Start CodeMySpec becomes available.
5. Exercise a database startup failure after checks pass, such as invalid application database credentials in the disposable environment. Starting CodeMySpec must report the failure on the still-responsive setup page. It must not terminate the window or overwrite the successful prerequisite results.
6. Correct the database configuration and retry startup. Verify the main app becomes reachable through Continue to CodeMySpec. Confirm normal user initialization, migrations, and harness startup still occur.

The setup listener binds to loopback on an OS-assigned port. Its URL contains a per-launch access token; redact that token from shared evidence. Unknown tokens and cross-origin POST actions must be refused.

Automated coverage is in test/code_my_spec_desktop/bootstrap_test.exs. It exercises the real loopback HTTP listener with a window observer, isolated prerequisite executables, and a runtime fixture that refuses startup. This does not replace a packaged desktop/native-window QA pass. Compiler run 57980 passed without blocking findings. ExUnit run 57991 passed after correcting the generator test runner. Subsequent edits route bootstrap test actions through HTTP and simplify setup persistence; these edits still need validation. Credo rerun 57993 was requested after converting direct spec file calls to the environment API; its result is pending. Full story acceptance and packaged desktop QA remain outstanding.
