defmodule CodeMySpec.ResourcesTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Projects
  alias CodeMySpec.Provisioning.{RunLock, StepRepository}
  alias CodeMySpec.Resources
  alias CodeMySpec.WorkingCopies

  # Fake providers only — these tests exist to prove the async handoff and
  # the lock, not to exercise real steps. `Resources.fix/2`/`fix_async/2`
  # thread opts through the *global* `:provisioning_step_opts` config (there
  # is no per-call opts parameter on `Resources.fix/2`), which is why this
  # module runs `async: false`: two tests mutating the same global config
  # concurrently would race each other exactly like the bug under test.
  setup do
    # `config/test.exs` runs `start_fix/2` inline everywhere else, same
    # reasoning as `content_pull_async: false` — but that is precisely the
    # behavior this module exists to prove is NOT what happens. Forced back
    # on here, locally, so these tests still see the real handoff.
    previous_async = Application.get_env(:code_my_spec, :provisioning_async, true)
    Application.put_env(:code_my_spec, :provisioning_async, true)
    on_exit(fn -> Application.put_env(:code_my_spec, :provisioning_async, previous_async) end)

    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    Application.put_env(:code_my_spec, :provisioning_step_opts,
      verify: fn _scope, _key -> {:ok, :absent} end,
      execute: fn _scope, _key, _opts -> {:ok, []} end
    )

    on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end)

    %{scope: full_scope_fixture()}
  end

  describe "fix_async/2" do
    test "a project not on the account", %{scope: scope} do
      assert Resources.fix_async(scope, Ecto.UUID.generate()) == {:error, :not_found}
    end

    # The whole point of the fix: this must return long before a real run
    # would finish. It is proven here by a fake step that finishes instantly,
    # but the shape being tested — return on "started", not on "done" — is
    # the same either way.
    test "starts the run in the background and returns before it finishes", %{scope: scope} do
      project_id = scope.active_project.id

      assert {:ok, :started} = Resources.fix_async(scope, project_id)
      assert StepRepository.get(scope, :repository) == nil, "must not block for the run itself"

      # Waiting for the *last* step in the sequence, not just the first,
      # matters here for more than thoroughness: `Provisioning.run/3` (called
      # directly, not through `run_async/3`) never broadcasts a "finished"
      # message, only a `:step` transition per step — and the background task
      # keeps running against this test's sandboxed connection after the
      # assertion above returns. Letting the test process exit while it is
      # still mid-sequence tears that connection down out from under it.
      # Waited on `:done`, not on the row existing — see `step_state/2`.
      wait_until(fn -> step_state(scope, :repository) == :done end)
      wait_until(fn -> step_state(scope, :callback_credential) == :done end)

      assert StepRepository.get(scope, :repository).state == :done
      assert StepRepository.get(scope, :callback_credential).state == :done
    end

    # The confirmed-live race: a caller retries `run_devops_setup` for a
    # project whose previous call is still running, believing the first
    # attempt failed (an MCP transport timeout, not a real failure). Without
    # the lock, this starts a second `Provisioning.run/3` against the same
    # project's real provider state.
    test "refuses a second run for a project that already has one in flight", %{scope: scope} do
      project_id = scope.active_project.id
      test_pid = self()

      # Stands in for "a run is already in flight" without needing a real,
      # slow step to hold it open.
      holder =
        spawn(fn ->
          RunLock.with_lock(project_id, fn ->
            send(test_pid, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :locked

      assert {:error, {:already_running, started_at}} = Resources.fix_async(scope, project_id)
      assert %DateTime{} = started_at

      # Refused before touching a provider or writing a row — the second
      # call never reached `Provisioning.run/3` at all.
      assert StepRepository.get(scope, :repository) == nil

      send(holder, :release)
    end
  end

  describe "fix_all_async/1" do
    test "nothing to start when no project has devops enabled", %{scope: scope} do
      assert Resources.fix_all_async(scope) == []
    end

    test "starts every project whose devops level is not off", %{scope: scope} do
      {:ok, _config} = Configurations.update(scope, %{devops: :uat})
      project_id = scope.active_project.id

      assert [{^project_id, {:ok, :started}}] = Resources.fix_all_async(scope)

      # Waited on `:done`, not on the row existing — see `step_state/2`.
      wait_until(fn -> step_state(scope, :repository) == :done end)
      wait_until(fn -> step_state(scope, :callback_credential) == :done end)

      assert StepRepository.get(scope, :repository).state == :done
      assert StepRepository.get(scope, :callback_credential).state == :done
    end
  end

  # Story a2ea10a8: `/app/resources`' "Run setup" button hands `project_scope/2`
  # a plain web-session scope, which — unlike a harness-connected scope, and
  # unlike the fixtures elsewhere in this file — carries no `environment` at
  # all. Steps that shell out (`:repository` chief among them, since
  # `verify(:repository, …)` always answers `{:ok, :absent}` and so re-runs on
  # every pass) read that as "nowhere to run commands" and erred, flipping a
  # genuinely intact repository from `:done` back to `:error` on every account
  # page click.
  describe "project_scope/2" do
    test "resolves a runnable environment from the project's own checkout, even when the caller's scope has none",
         %{scope: scope} do
      {:ok, checkout} = Briefly.create(directory: true)

      {:ok, project} =
        Projects.update_project(scope, scope.active_project, %{local_path: checkout})

      # What a browser-session scope actually looks like — `Scope.for_user/1`
      # never populates `environment`.
      web_scope = %{scope | environment: nil}

      resolved = Resources.project_scope(web_scope, project)

      assert %Environment{type: :local, cwd: ^checkout} = resolved.environment
      assert resolved.active_project_id == project.id
    end

    test "leaves the environment nil for a project with no reachable checkout anywhere, rather than guessing one",
         %{scope: scope} do
      {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: nil})

      web_scope = %{scope | environment: nil}

      resolved = Resources.project_scope(web_scope, project)

      assert resolved.environment == nil
      assert resolved.active_project_id == project.id
    end

    test "a harness-typed scope still re-derives :local from the project's checkout, unaffected by this fix",
         %{scope: scope} do
      {:ok, checkout} = Briefly.create(directory: true)

      {:ok, project} =
        Projects.update_project(scope, scope.active_project, %{local_path: checkout})

      harness_scope = %{
        scope
        | environment: Environment.new(:harness, "/wherever/the/harness/runs")
      }

      resolved = Resources.project_scope(harness_scope, project)

      assert %Environment{type: :local, cwd: ^checkout} = resolved.environment
    end

    test "a scope that already carries a real environment keeps it, e.g. an MCP/CLI caller",
         %{scope: scope} do
      resolved = Resources.project_scope(scope, scope.active_project)

      assert resolved.environment == scope.environment
    end

    # Found live: a project onboarded outside the usual local_path-setting
    # flow (an adopted, pre-existing checkout) has no persisted column, but
    # its harness is live-registered and connected right now. The harness
    # clause used to go straight to `project.local_path` and never asked the
    # registry at all, so a shelling-out step read "no working directory" for
    # a project a real, active harness could answer for.
    test "a harness-typed scope finds a live-registered checkout even with no local_path column",
         %{scope: scope} do
      {:ok, checkout} = Briefly.create(directory: true)

      {:ok, project} =
        Projects.update_project(scope, scope.active_project, %{local_path: nil})

      :ok = CodeMySpec.Environments.register(project.id, Environment.new(:local, checkout))
      on_exit(fn -> CodeMySpec.Environments.unregister(project.id) end)

      harness_scope = %{
        scope
        | environment: Environment.new(:harness, "/wherever/the/harness/runs")
      }

      resolved = Resources.project_scope(harness_scope, project)

      assert %Environment{type: :local, cwd: ^checkout} = resolved.environment
    end

    # Found live against Broken Oaths' real project: never onboarded through
    # any local_path-setting flow, no spex-style registry entry (that
    # mechanism is test-only — CodeMySpec.Environments.register/2's own doc
    # says so), but a harness joined moments earlier with a real, known root.
    # `adopt_repository` died on "this environment has no working directory"
    # for a checkout that was live and connected the whole time.
    test "a harness-typed scope uses the caller's own connected working copy when local_path and the registry both have nothing",
         %{scope: scope} do
      {:ok, checkout} = Briefly.create(directory: true)

      {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: nil})

      scoped = %{scope | active_project_id: project.id}

      {:ok, working_copy} =
        WorkingCopies.issue(scoped, nil, root: checkout, device: device_fixture(scoped))

      {:ok, working_copy} = WorkingCopies.report_root(working_copy, checkout)

      harness_scope = %{
        scope
        | environment: Environment.new(:harness, "/wherever/the/harness/runs"),
          active_working_copy_id: working_copy.id
      }

      resolved = Resources.project_scope(harness_scope, project)

      assert %Environment{type: :local, cwd: ^checkout} = resolved.environment
    end

    # The connected copy only answers for its *own* project. A caller bound to
    # one project's working copy asking about a different project must not
    # borrow that root — same reasoning that already guards the module's
    # "iterating over project B" case, just reached through a live connection
    # instead of a stale one.
    test "a harness-typed scope ignores the connected working copy when it belongs to a different project",
         %{scope: scope} do
      {:ok, own_checkout} = Briefly.create(directory: true)
      {:ok, other_checkout} = Briefly.create(directory: true)

      # The working copy belongs to the caller's own project (scope.active_project) —
      # the one it is genuinely connected for.
      {:ok, working_copy} =
        WorkingCopies.issue(scope, nil, root: own_checkout, device: device_fixture(scope))

      {:ok, working_copy} = WorkingCopies.report_root(working_copy, own_checkout)

      # But the call asks about a completely different project — its own
      # local_path is the only honest answer here, never the caller's checkout.
      other_project = project_fixture(scope, %{local_path: other_checkout})

      harness_scope = %{
        scope
        | environment: Environment.new(:harness, "/wherever/the/harness/runs"),
          active_working_copy_id: working_copy.id
      }

      resolved = Resources.project_scope(harness_scope, other_project)

      assert %Environment{type: :local, cwd: ^other_checkout} = resolved.environment
    end
  end

  # The state of a step, or `nil` while it has not been written yet.
  #
  # Both callers used to wait on `StepRepository.get(...) != nil` and then
  # assert the state was `:done`. A step row is written when the step *starts*
  # and updated when it finishes, so that wait was satisfied by the exact state
  # the assertion rejects: the two were about different things, and the gap
  # between them was however long the work actually took. It passed only while
  # the machine was quiet enough for a step to finish inside one 10ms tick.
  #
  # Both tests in this file that used it were intermittent in full-suite runs.
  # Caught 2026-08-20:
  #
  #     assert StepRepository.get(scope, :callback_credential).state == :done
  #     left:  :running
  #
  # `nil` rather than raising for an unwritten step, because that is the
  # ordinary state while async work is starting and it is what the wait is for.
  defp step_state(scope, step), do: scope |> StepRepository.get(step) |> state_of()

  defp state_of(nil), do: nil
  defp state_of(record), do: record.state

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition never became true")
  defp wait_until(fun, attempts), do: retry_until(fun.(), fun, attempts)

  defp retry_until(true, _fun, _attempts), do: :ok

  defp retry_until(_falsy, fun, attempts) do
    Process.sleep(10)
    wait_until(fun, attempts - 1)
  end
end
