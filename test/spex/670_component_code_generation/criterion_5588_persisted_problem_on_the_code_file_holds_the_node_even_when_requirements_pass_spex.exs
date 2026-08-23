defmodule CodeMySpecSpex.Story670.Criterion5588Spex do
  @moduledoc """
  Story 670 — Component Code Generation
  Criterion 5588 — Persisted problem on the code file holds the node
  even when requirements pass.

  Surface: stop hook drives Validation + TaskEvaluator. With an active
  ComponentCode task whose `implementation_file` requirement is
  satisfied (impl on disk via `:synced_context_component`) and a
  compile-error JSONL fixture targeting the code file, the pipeline
  short-circuits at compile and persists the problem. The stop hook
  blocks with the compile diagnostic in the reason — proving the
  evaluation gate honors persisted problems even when the file-level
  requirement is satisfied.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  @code_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Code Generation" do
    scenario "Persisted problem on the code file holds the node even when requirements pass" do
      given_ :synced_context_component

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

      given_ "the agent writes a code file with a syntax error", context do
        :ok =
          Environments.write_file(
            context.environment,
            @code_path,
            """
            defmodule ExampleContext do
              # malformed — missing `end`
            """
          )

        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response =
          use_cmd_cassette "pipeline_compile_error", record: :none do
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

      then_ "the stop is blocked with the compile error in the reason", context do
        assert context.response["decision"] == "block",
               "compile error on the code file must block, got: #{inspect(context.response)}"

        reason = context.response["reason"]
        assert is_binary(reason)

        assert reason =~ ~r/compil|syntax/i,
               "reason must mention compilation/syntax, got:\n#{reason}"

        assert reason =~ @code_path,
               "reason must reference the offending code file, got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
