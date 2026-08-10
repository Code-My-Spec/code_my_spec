defmodule CodeMySpecSpex.Story553.Criterion6072Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 6072 — When spec_validation is set to block_all, persisted
  spec_validation problems block the stop every turn until the spec file
  is fixed — even turns that don't touch the file.

  This is the old always-blocking behavior, now opt-in via config. Two
  turns: turn 1 seeds a broken spec, turn 2 fires with no changes and
  still gets blocked.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @broken_spec_path ".code_my_spec/spec/todo/broken.spec.md"
  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sets spec_validation to block_all" do
    scenario "stub spec files in the DB block every turn until fixed" do
      given_ :synced_context_component
      given_ :on_configuration_page

      given_ "spec_validation is set to block_all", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{spec_validation: "block_all"}
        )
        |> render_submit()

        {:ok, context}
      end

      given_ "turn 1: the agent writes a broken spec file and fires the stop hook",
             context do
        :ok =
          Environments.write_file(
            context.environment,
            @broken_spec_path,
            broken_spec()
          )

        _turn_1_response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
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
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked with the persisted spec_validation problem",
            context do
        assert context.response["decision"] == "block",
               "block_all must block on persisted spec_validation problems, got: #{inspect(context.response)}"

        assert context.response["reason"] =~ "spec_validation",
               "reason must mention spec_validation, got: #{inspect(context.response["reason"])}"

        assert context.response["reason"] =~ @broken_spec_path,
               "reason must reference the broken spec file, got: #{inspect(context.response["reason"])}"

        {:ok, context}
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
