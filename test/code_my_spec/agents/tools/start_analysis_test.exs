defmodule CodeMySpec.Agents.Tools.StartAnalysisTest do
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Tools.StartAnalysis

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.FleetHolds
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.RunsRepository

  setup do
    scope = full_scope_fixture()
    %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}}
  end

  test "returns a persisted run id before the harness has executed anything", %{
    scope: scope,
    frame: frame
  } do
    assert :ok = HarnessRegistry.register_executor(scope.active_working_copy_id)

    response =
      ToolLibrary.run(
        "start_analysis",
        %{source: "compiler"},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, response)
    # Forced, as only a forced compiler run certifies a commit.
    assert_receive {:run_analysis,
                    [%{"run_id" => run_id, "source" => "compiler", "args" => ["--force"]}]}

    assert text(response) =~ "Run #{run_id}"
    run = RunsRepository.get_run_in_project(scope, run_id)
    assert run.status == :running
    assert run.requested_by["tool"] == "start_analysis"
  end

  # A /dev/qa-agents agent is a terminal agent QA drives over MCP: no session
  # of its own receives the result, and QA waited five hours for it.
  test "a terminal agent is told how to read its result itself", %{scope: scope, frame: frame} do
    assert :ok = HarnessRegistry.register_executor(scope.active_working_copy_id)

    {:ok, terminal} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :claude_code,
        role: "qa",
        status: :running,
        engine_session_id: "qa-#{Ecto.UUID.generate()}",
        working_copy: "/tmp/qa-terminal",
        working_copy_id: scope.active_working_copy_id
      })

    response =
      ToolLibrary.run(
        "start_analysis",
        %{source: "compiler", paths: ["lib/a.ex"]},
        frame.assigns |> Map.put(:scope, scope) |> Map.put(:agent_id, terminal.id)
      )

    assert_receive {:run_analysis, [%{"run_id" => run_id}]}
    assert text(response) =~ "get_analysis_output({run_id = #{run_id}})"
  end

  test "paths scopes the run to specific files instead of the full suite", %{
    scope: scope,
    frame: frame
  } do
    assert :ok = HarnessRegistry.register_executor(scope.active_working_copy_id)

    response =
      ToolLibrary.run(
        "start_analysis",
        %{source: "exunit", paths: ["test/code_my_spec/qa/issue_qa_resumes_test.exs"]},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, response)

    assert_receive {:run_analysis,
                    [
                      %{
                        "run_id" => run_id,
                        "source" => "exunit",
                        "args" => ["test/code_my_spec/qa/issue_qa_resumes_test.exs"]
                      }
                    ]}

    run = RunsRepository.get_run_in_project(scope, run_id)
    assert run.status == :running
  end

  test "omitting paths runs the full suite, as before", %{scope: scope, frame: frame} do
    assert :ok = HarnessRegistry.register_executor(scope.active_working_copy_id)

    response =
      ToolLibrary.run(
        "start_analysis",
        %{source: "exunit"},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, response)
    assert_receive {:run_analysis, [%{"source" => "exunit", "args" => []}]}
  end

  test "refuses a disconnected checkout when the web app has no local executor", %{
    scope: scope,
    frame: frame
  } do
    # The web app runs `:async` and has no `ServerSupervisor`; both halves are
    # needed to be it. Under the test env's `:inline` a run executes in-process,
    # which is always available, so removing the supervisor alone models nothing.
    previous = Application.get_env(:code_my_spec, :analysis_mode)
    Application.put_env(:code_my_spec, :analysis_mode, :async)
    on_exit(fn -> Application.put_env(:code_my_spec, :analysis_mode, previous) end)

    :ok = Supervisor.terminate_child(Analysis.Supervisor, Analysis.ServerSupervisor)
    on_exit(fn -> Supervisor.restart_child(Analysis.Supervisor, Analysis.ServerSupervisor) end)
    assert Process.whereis(Analysis.ServerSupervisor) == nil

    response =
      ToolLibrary.run(
        "start_analysis",
        %{source: "compiler"},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:error, _}, response)
    assert text(response) =~ "no harness is connected"
    assert RunsRepository.latest_full_runs(scope) == %{}
  end

  test "a fleet hold refuses admission, naming why, and lifting lets it proceed", %{
    scope: scope,
    frame: frame
  } do
    assert :ok = HarnessRegistry.register_executor(scope.active_working_copy_id)
    {:ok, _hold} = FleetHolds.place(scope, "load 40, five agents running tests")

    held_response =
      ToolLibrary.run(
        "start_analysis",
        %{source: "compiler"},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:error, _}, held_response)
    assert text(held_response) =~ "fleet hold is in force"
    assert text(held_response) =~ "load 40, five agents running tests"
    assert RunsRepository.latest_full_runs(scope) == %{}

    {:ok, _} = FleetHolds.lift(scope)

    lifted_response =
      ToolLibrary.run(
        "start_analysis",
        %{source: "compiler"},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, lifted_response)
    assert_receive {:run_analysis, [%{"source" => "compiler"}]}
  end

  test "an invalid source returns an error without opening a run", %{scope: scope, frame: frame} do
    response =
      ToolLibrary.run(
        "start_analysis",
        %{source: "unknown"},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:error, _}, response)
    assert RunsRepository.latest_full_runs(scope) == %{}
  end

  test "database read exceptions are returned to the caller", %{scope: scope, frame: frame} do
    invalid_scope = %{scope | active_working_copy_id: "not-a-uuid"}
    frame = %{frame | assigns: %{current_scope: invalid_scope}}

    response =
      ToolLibrary.run(
        "start_analysis",
        %{source: "compiler"},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:error, _}, response)
    assert text(response) =~ "Could not admit compiler"
    assert RunsRepository.latest_full_runs(scope) == %{}
  end

  defp text({_status, text}) when is_binary(text), do: text

  defp text(response) do
    response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")
  end

  describe "the real MCP schema validation" do
    # 80ab27be: every call above builds `params` already atom-keyed and
    # pre-shaped, so execute/2 never actually exercised the schema Peri
    # derives from `schema do ... end` -- which is what a real MCP request
    # goes through first. `paths, {:array, :string}` passed every test above
    # and still failed every real caller with a bare "Invalid params": Peri's
    # list type is `{:list, type}`, not `{:array, type}`, and `{:array, ...}`
    # read as an unsupported shape, reported back as "expected a nested
    # schema". `mcp_schema/1` is what Peri's own `defschema` generates and
    # what actually runs before `execute/2` in production; calling it
    # directly, string-keyed the way a decoded MCP request arrives, is the
    # schema-validation layer itself, without standing up a full transport.
    test "paths as a list of strings validates" do
      assert {:ok, validated} =
               CodeMySpec.Tools.validate(StartAnalysis, %{
                 "source" => "exunit",
                 "paths" => ["test/code_my_spec/some_test.exs"]
               })

      assert validated.paths == ["test/code_my_spec/some_test.exs"]
    end

    test "omitting paths validates and defaults to empty" do
      assert {:ok, validated} = CodeMySpec.Tools.validate(StartAnalysis, %{"source" => "exunit"})
      assert validated.paths == []
    end

    test "an empty paths list validates" do
      assert {:ok, validated} =
               CodeMySpec.Tools.validate(StartAnalysis, %{"source" => "exunit", "paths" => []})

      assert validated.paths == []
    end
  end
end
