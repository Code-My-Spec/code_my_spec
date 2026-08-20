defmodule CodeMySpec.ResourcesTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.Provisioning.{RunLock, StepRepository}
  alias CodeMySpec.Resources

  # Fake providers only — these tests exist to prove the async handoff and
  # the lock, not to exercise real steps. `Resources.fix/2`/`fix_async/2`
  # thread opts through the *global* `:provisioning_step_opts` config (there
  # is no per-call opts parameter on `Resources.fix/2`), which is why this
  # module runs `async: false`: two tests mutating the same global config
  # concurrently would race each other exactly like the bug under test.
  setup do
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
      wait_until(fn -> StepRepository.get(scope, :callback_credential) != nil end)
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

      wait_until(fn -> StepRepository.get(scope, :callback_credential) != nil end)
      assert StepRepository.get(scope, :repository).state == :done
      assert StepRepository.get(scope, :callback_credential).state == :done
    end
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
