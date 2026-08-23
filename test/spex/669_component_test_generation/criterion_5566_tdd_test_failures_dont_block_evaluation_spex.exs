defmodule CodeMySpecSpex.Story669.Criterion5566Spex do
  @moduledoc """
  Story 669 — Component Test Generation
  Criterion 5566 — TDD test failures don't block evaluation.

  Surface: stop hook drives Validation + TaskEvaluator. With an active
  ComponentTest task and a written test file, the pipeline does NOT
  invoke `mix test --stale` (ComponentTest declares only `:credo` and
  the role-derived analyzers for `:test` no longer include
  `:exunit_stale`). No exunit problems land, no blocking happens, and
  the stop is allowed.

  This is the structural form of TDD tolerance: while writing tests
  before the implementation exists, exunit isn't expected to pass —
  so we just don't run it. The test file's compile + credo still
  guard the artifact.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  @test_path "test/example_context_test.exs"
  @fixture_dir "test/fixtures/validation/component_test_tdd_no_exunit"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Test Generation" do
    scenario "TDD test failures don't block evaluation" do
      given_ :synced_context_component

      given_ "the agent has signalled session start and started a test_file task", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "test_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id
            },
            frame
          )

        {:ok, Map.put(context, :session_id, session_id)}
      end

      given_ "the agent writes a test that calls a function the implementation doesn't expose",
             context do
        :ok =
          Environments.write_file(
            context.environment,
            @test_path,
            """
            defmodule ExampleContextTest do
              use ExUnit.Case

              test "calls a missing function" do
                assert ExampleContext.not_implemented_yet() == :ok
              end
            end
            """
          )

        {:ok, context}
      end

      when_ "the stop hook fires", context do
        # Cassette covers `mix compile --return-errors` only — if the
        # pipeline ever tries `mix test --stale` for a ComponentTest
        # task, ExCliVcr will raise CassetteNotFoundError, surfacing
        # the regression immediately.
        response =
          use_cmd_cassette "component_test_tdd_no_exunit", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{"compile" => fixture_path("compile.jsonl")}
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed despite the would-be failing test", context do
        assert context.response == %{},
               "ComponentTest task must allow the stop without running exunit, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
