# Rooting out flaky tests

A flaky test passes and fails on the same code. In a promotion queue every
flake costs a whole gate run, plus the re-run, plus everyone queued behind it,
and once candidates are batched one flake ejects the batch. Treat a flake as a
bug with a cause, find the cause, and prove the fix.

## What counts as a flake

- **Confirmed:** the same test passed at the same commit (or the same tree)
  in another run. Re-promoting the unchanged commit and watching it land is
  the cheapest proof.
- **Suspect:** the same test failed in several unrelated candidates. A test
  that fails only beside other suites is still a flake.
- **Not a flake:** the failure follows the change. A merge that breaks a
  pattern match, or a test the change really broke, is a defect; fix it as
  one.

Read the failure first. A timeout, `{:error, :busy}`, a missing file or a
DB ownership error points at timing or isolation; an assertion on a value the
change touched usually points at the change.

## Reproduce before fixing

A fix you never saw fail proves nothing. Make it fail on demand, then make it
pass the same way.

1. **Alone, repeated.** `mix test path/to/test.exs --repeat-until-failure 50`.
   A test that fails here has a race inside itself.
2. **Starve the BEAM, not the machine.** Most flakes are races inside the
   VM: an async task, a GenServer reply, a LiveView `assign_async`. Run the
   test on one scheduler so those orderings come up:

   ```
   MIX_ENV=test mix compile
   ELIXIR_ERL_OPTIONS="+S 1:1" nice -n 10 mix test path/to/test.exs --repeat-until-failure 50
   ```

   Compile first: compiling on one scheduler is very slow. `nice` keeps the
   run out of the way of anything else on the machine.
3. **A CPU-capped container,** only if the starved BEAM will not reproduce
   it: run the suite in a container limited to one CPU (`docker run
   --cpus=1 ...`).
4. **Never load the host.** `yes > /dev/null` or similar CPU burners slow
   every other test run on the machine, including promotion gates, which then
   time out and eject unrelated work. Agents cannot see when a gate is
   running, so this rule has no exceptions.
5. **Beside its neighbours.** A test that only fails in the full suite shares
   state with another test: run its directory, then the suites around it, and
   look for what they share.

If nothing reproduces it, read the code for the race instead of forcing it.

## Fix the cause, not the wait

Raising a timeout makes the flake rarer and slower; it is never the fix.
Wait on the event that makes the assertion true.

| Symptom | Usual cause | Fix |
|---|---|---|
| `expected async processes to finish within 100ms` | The LiveView started async work the test does not await | Monitor `Phoenix.LiveView.Channel.async_pids/1` and wait for each to exit before rendering |
| `{:error, :busy}` sending to a process | Something else started a turn first (often startup work) | Wait for the process to be idle (`await_idle`) before arranging the scenario |
| A status read once after an async change is stale | The UI follows the change asynchronously | Put the read inside the same `eventually` as the change it follows |
| A poll gives up after a fixed number of tries | The budget is shorter than the work on a loaded machine | Wait on the task that writes the state: monitor it and receive `:DOWN` |
| A spawned process outlives its test (`DBConnection.OwnershipError`, `owner exited`) | Fire-and-forget work still running at teardown | Drain the tasks the test started before the sandbox owner stops |
| `test timed out after 60000ms` scanning many files | Per-item work that loads code (`mod.module_info/1` on every module) | Read what you need from the artifact (beam chunks), check the cheap condition first, and parallelise |
| A helper waits 1s for an external process to write a file | OS process start is milliseconds idle, seconds under load | A real deadline (15s) on the same poll, or wait on the event itself |
| Passes alone, fails in the suite | Shared global state: an unscoped `update_all`, a machine-wide name, an id reused across test databases | Scope the write to the test's own rows; make names unique per OS process |
| Fails on `mix deps.get`, `could not write to file` | The disk is full | Not a flake: free the disk and find what is leaking temp files |

## Prove both arms

Before you commit a flake fix, show it fails on the old code and passes on the
new one, under the same conditions:

```
git diff path/to/test.exs > /tmp/fix.patch && git checkout path/to/test.exs
ELIXIR_ERL_OPTIONS="+S 1:1" mix test path/to/test.exs --repeat-until-failure 50   # fails
git apply /tmp/fix.patch
ELIXIR_ERL_OPTIONS="+S 1:1" mix test path/to/test.exs --repeat-until-failure 50   # passes
```

When the old code will not fail even starved, say so in the commit message
and name the race you read in the code; do not claim a reproduction you did
not see.

## Keep tests from causing flakes

- **Assert on counts, never on duration.** A test that times its subject is a
  flake by construction; count queries, rows or calls instead, and compare
  two sizes ("does not grow with the number of files") rather than pinning a
  number.
- **No control flow in tests,** and no `Process.sleep` to wait for something:
  wait on the thing.
- **Clean up after yourself.** Every temp directory, generated app and
  fixture a test creates must be removed when it ends (`@tag :tmp_dir`, or
  `on_exit`). Leaked temp files fill the disk, and a full disk makes every
  later run fail at random.
- **Make shared names unique** per OS process (`System.pid()`), not just per
  test, when several suites run on one machine at once.
