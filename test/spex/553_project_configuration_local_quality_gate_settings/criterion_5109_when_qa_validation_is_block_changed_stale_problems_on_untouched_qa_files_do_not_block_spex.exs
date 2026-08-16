defmodule CodeMySpecSpex.Story553.Criterion5109Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5109 — When qa_validation is block_changed (the default),
  persisted qa_validation problems for qa briefs the agent did not
  modify this turn do not block the stop. Parallel to 5105 for the
  qa_validation source.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  # qa_dir is `.code_my_spec/qa/{story_id}/brief.md` — see FileSync.classify_qa.
  # We use 9999 as a stub story id the test sets up implicitly (no Story
  # record required for classification — FileSync just needs the path pattern).
  @broken_qa_brief_path ".code_my_spec/qa/9999/brief.md"
  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer leaves qa_validation at default block_changed" do
    scenario "stub qa briefs in the DB don't block turns that didn't touch them" do
      given_ :synced_context_component
      given_ :on_configuration_page

      given_ "qa_validation is set to block_changed (default)", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{qa_validation: "block_changed"}
        )
        |> render_submit()

        {:ok, context}
      end

      given_ "turn 1: the agent writes a broken qa brief and fires the stop hook",
             context do
        :ok =
          Environments.write_file(
            context.environment,
            @broken_qa_brief_path,
            broken_qa_brief()
          )

        _turn_1_response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{
            "test_output_files" => %{
              "compile" => fixture_path("compile.jsonl")
            }
          })
          |> Phoenix.ConnTest.json_response(200)

        {:ok, context}
      end

      when_ "turn 2: the stop hook fires with no file changes", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed because the broken brief is outside task scope",
            context do
        assert context.response == %{},
               "block_changed must treat untouched qa_validation problems as advisory, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp broken_qa_brief do
    """
    # QA Brief

    A stub qa brief missing required sections.
    """
  end
end
