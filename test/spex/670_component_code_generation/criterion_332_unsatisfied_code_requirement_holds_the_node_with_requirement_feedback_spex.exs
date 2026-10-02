defmodule CodeMySpecSpex.Story670.Criterion5587Spex do
  @moduledoc """
  Story 670 — Component Code Generation
  Criterion 5587 — Unsatisfied code requirement holds the node with
  requirement feedback.

  Surface: design a context Component — no implementation file on
  disk — then drive the stop hook on a clean
  pipeline run. With the `implementation_file` artifact requirement
  unsatisfied, the evaluator framework blocks the stop and emits
  feedback framed as "Requirement not met:" naming the missing
  implementation file so the agent has a path to fix it.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.ComponentGraphHelpers, only: [design!: 4]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  @module_name "ExampleNoImpl"
  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Code Generation", criterion: 332 do
    scenario "Unsatisfied code requirement holds the node with requirement feedback" do
      given_ "a context Component is designed with no implementation file on disk", context do
        component =
          design!(context, @module_name, [],
            description: "A context whose implementation file has not been written yet."
          )

        {:ok, Map.put(context, :component, component)}
      end

      given_ "the agent has signalled session start and started an implementation_file task",
             context do
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
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id
            },
            frame
          )

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the stop hook fires with a clean pipeline run", context do
        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
                "compile" => fixture_path("compile.jsonl"),
                "exunit" => fixture_path("exunit.json")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked with requirement feedback naming the missing impl",
            context do
        assert context.response["decision"] == "block",
               "expected the stop to be blocked because implementation_file is unsatisfied, got: #{inspect(context.response)}"

        reason = context.response["reason"] || ""

        assert reason =~ "Requirement not met:",
               "expected the feedback to be framed as 'Requirement not met:', got: #{reason}"

        assert reason =~ "lib/example_no_impl.ex",
               "expected the missing implementation file path in the feedback, got: #{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
