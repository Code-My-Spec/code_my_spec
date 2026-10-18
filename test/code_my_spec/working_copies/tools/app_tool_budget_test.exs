defmodule CodeMySpec.WorkingCopies.Tools.AppToolBudgetTest do
  @moduledoc """
  A tool a script calls must not wait longer than the script can survive.

  Issue 0b1ae6fc. `restart_app` through `run_script` crashed on an MCP
  transport timeout instead of returning an outcome. The cause was not the
  restart's cost: `restart_app` and `ensure_app_running` declared
  `@timeout to_timeout(minute: 3)` — 180s — while the script that calls them
  runs under `CodeMode.Sandbox`'s 30s wall clock, which hands each machine
  tool 28s (`CodeMode.@machine_call_margin_ms` below that). So the tool's own
  wait outlasted its caller six times over, the sandbox killed the script, and
  `AppTransport`'s careful `{:error, :restart_timed_out}` — the answer the
  caller needed — could never be returned. `stop_app`, declaring 30s, shows no
  such fault, which is how the mismatch hid.

  This is the same arithmetic `CodeModeTest` asserts for the *transport* call
  ("gives each call less than the script has"), one layer further in: the
  number the tool waits on must fit inside the script too.

  A restart that genuinely needs longer than the sandbox still cannot complete
  in-script — this bounds the wait so the tool *reports* that rather than
  vanishing. Returning on acceptance and reporting the outcome separately, the
  way `promote` and `start_analysis` do, is the follow-up.

  4d727b2c: `script_call_budget/0` below used to subtract `CodeMode`'s own
  `@machine_call_margin_ms` (2_000, fixed) — but `EnsureAppRunning` and
  `RestartApp` are plain `ScriptableTools`, reached through `invoker/3`'s
  direct `execute/2` call, never through `machine_catalog/3`'s wrapper; that
  margin was never actually enforced on this call path, only borrowed by
  convention. The real ceiling is `AppTransport.call/4`'s own grace
  (`AppTransport.call_grace_ms/0`), added on top of whatever timeout
  `AppTransport.ensure_app_running/2` and `.restart_app/2` are given — so the
  true deadline a tool's internal wait can reach is `declared_timeout() +
  call_grace_ms()`, and that is what has to fit under the sandbox clock.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.CodeMode.Sandbox
  alias CodeMySpec.McpServers.CodeMode, as: Layer
  alias CodeMySpec.WorkingCopies.Tools.{EnsureAppRunning, RestartApp}
  alias CodeMySpec.WorkingCopies.AppTransport

  # What a script can actually wait for: the sandbox clock less the grace
  # `AppTransport.call/4` adds on top of whatever timeout it is given — the
  # real ceiling these two tools' own `declared_timeout/0` must fit under.
  defp script_call_budget do
    Sandbox.timeout([]) - AppTransport.call_grace_ms()
  end

  describe "a script's own machine tools" do
    test "restart_app does not wait longer than the script that calls it" do
      declared = RestartApp.declared_timeout()

      assert declared <= script_call_budget(),
             """
             restart_app waits #{declared}ms while the script calling it has only \
             #{script_call_budget()}ms. The sandbox expires first, kills the script, \
             and AppTransport's :restart_timed_out never reaches the caller — \
             the crash in 0b1ae6fc.
             """
    end

    test "ensure_app_running does not wait longer than the script that calls it" do
      declared = EnsureAppRunning.declared_timeout()

      assert declared <= script_call_budget(),
             """
             ensure_app_running waits #{declared}ms inside a #{script_call_budget()}ms \
             script, so a slow first boot is killed rather than reported as a timeout \
             the caller can read.
             """
    end

    test "and still leaves room for the transport to answer" do
      # The floor matters as much as the ceiling: a budget below what a real
      # call takes turns every restart into a timeout.
      assert RestartApp.declared_timeout() >= 1_000
    end
  end

  describe "the budget a real script hands these tools" do
    setup do
      # The catalog is built from the registered scope, so this covers the
      # wiring rather than the module's own arithmetic.
      scope =
        full_scope_fixture()
        |> Map.put(:active_working_copy_id, "budget-test-copy")

      {:ok, scope: scope}
    end

    test "is what the tools are told to expect", %{scope: scope} do
      catalog = Layer.machine_catalog(scope, nil, script_call_budget())

      for name <- ~w(restart_app ensure_app_running) do
        assert_bounded(catalog, name)
      end
    end
  end

  # Not on this machine's catalog: nothing to bound here.
  defp assert_bounded(catalog, name) when not is_map_key(catalog, name), do: :ok

  defp assert_bounded(catalog, name) do
    %{timeout: given} = Map.fetch!(catalog, name)

    assert given <= RestartApp.declared_timeout(),
           """
           the catalog hands #{name} #{given}ms while the tool itself waits \
           #{RestartApp.declared_timeout()}ms — the inner wait outlasts the \
           call wrapping it, which is the mismatch this closes.
           """
  end
end
