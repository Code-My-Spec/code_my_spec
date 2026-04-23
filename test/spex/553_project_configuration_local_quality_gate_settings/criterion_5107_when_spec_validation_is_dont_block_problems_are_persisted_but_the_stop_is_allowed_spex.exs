defmodule CodeMySpecSpex.Story553.Criterion5107Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5107 — When spec_validation is set to dont_block, spec
  validator problems are still persisted (so the engineer can see them
  in the UI) but the stop is always allowed.

  Single turn: write a broken spec in the same turn, fire the stop
  hook, and observe that the blocking check demotes the problem.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @broken_spec_path ".code_my_spec/spec/todo/broken.spec.md"
  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sets spec_validation to dont_block" do
    scenario "broken spec files are persisted but don't block the stop" do
      given_ :synced_context_component
      given_ :on_configuration_page

      given_ "spec_validation is set to dont_block", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{spec_validation: "dont_block"}
        )
        |> render_submit()

        {:ok, context}
      end

      given_ "the agent writes a broken spec file", context do
        :ok =
          Environments.write_file(
            context.environment,
            @broken_spec_path,
            broken_spec()
          )

        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{
            "test_output_files" => %{
              "compile" => fixture_path("compile.jsonl")
            }
          })
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed despite the broken spec", context do
        assert context.response == %{},
               "dont_block must allow stop even when spec validation fails, got: #{inspect(context.response)}"

        :ok
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp broken_spec do
    """
    # Todo.Broken

    A stub spec that hasn't been filled in yet.
    """
  end
end
