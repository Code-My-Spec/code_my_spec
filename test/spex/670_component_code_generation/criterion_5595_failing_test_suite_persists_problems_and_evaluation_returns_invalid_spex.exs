defmodule CodeMySpecSpex.Story670.Criterion5595Spex do
  @moduledoc """
  Story 670 — Component Code Generation
  Criterion 5595 — Failing test suite persists problems and evaluation
  returns invalid.

  Surface: stop hook drives Validation + TaskEvaluator. With an active
  ComponentCode task, the project configured to block on exunit
  failures, and a pipeline run where the analyzer surfaces a failing
  test, the failure is persisted as a problem on the test file. The
  stop hook blocks with feedback naming the failing test so the agent
  can fix it next pass — the analyzer-fired-and-failed half of the
  exunit_stale contract.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"
  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Code Generation" do
    scenario "Failing test suite persists problems and evaluation returns invalid" do
      given_ :synced_context_component
      given_ :on_configuration_page

      given_ "the project is configured to block on exunit failures", context do
        context.config_live
        |> form("[data-test='configuration-form']", configuration: %{exunit: "block_all"})
        |> render_submit()

        {:ok, context}
      end

      given_ "the agent has signalled session start and started an implementation_file task",
             context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
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

      given_ "the agent edits the impl file during the task", context do
        # With microsecond-precision started_at, only files modified
        # post-start_task count as "changed during the task." Re-write
        # the impl file so the pipeline picks it up under the
        # block_changed scope.
        :ok =
          Environments.write_file(
            context.environment,
            @impl_path,
            "defmodule ExampleContext do\n  @moduledoc false\nend\n"
          )

        {:ok, context}
      end

      when_ "the stop hook fires after the analyzer ran the test suite and a test failed",
            context do
        response =
          use_cmd_cassette "pipeline_exunit_failure", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
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

      then_ "the stop is blocked with the failing test in the reason", context do
        assert context.response["decision"] == "block",
               "exunit failure with exunit:block must block, got: #{inspect(context.response)}"

        reason = context.response["reason"]
        assert is_binary(reason)

        assert reason =~ @test_path,
               "reason must reference the failing test file, got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
