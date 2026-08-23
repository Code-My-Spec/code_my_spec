defmodule CodeMySpecSpex.Story553.Criterion6076Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 6076 — When spec_validation is block_changed (the default)
  and the agent modifies a spec file that's missing a required section,
  the stop hook blocks with the validation error.

  Single-turn inverse of 6071: 6071 asserts that an untouched broken
  spec is demoted to advisory on the next turn; this spec asserts that
  the same broken spec, written *this turn*, blocks.

  Reuses the `pipeline_clean_run` compile fixture — there are no
  compile errors, only a spec validation failure. The spec file is in
  `changed_file_paths` because the agent wrote it this turn, so
  `block_changed` keeps the spec_validation problem as blocking.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @broken_spec_path ".code_my_spec/spec/todo/broken.spec.md"
  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Broken spec written this turn blocks under block_changed" do
    scenario "agent writes spec missing required section, stop blocks with the validation error" do
      given_ :synced_context_component
      given_ :on_configuration_page

      given_ "spec_validation is set to block_changed (default)", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{spec_validation: "block_changed"}
        )
        |> render_submit()

        {:ok, context}
      end

      given_ "the agent writes a spec file missing required sections", context do
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
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{
            "test_output_files" => %{
              "compile" => fixture_path("compile.jsonl")
            }
          })
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked", context do
        assert context.response["decision"] == "block",
               "block_changed must block when the changed spec is the source of the validation error, got: #{inspect(context.response)}"

        {:ok, context}
      end

      and_ "the block reason references the broken spec file or names a spec_validation failure",
           context do
        reason = context.response["reason"]

        assert is_binary(reason),
               "expected a reason string, got: #{inspect(context.response)}"

        assert reason =~ "broken.spec.md" or reason =~ ~r/spec_validation/i,
               "expected the reason to reference the broken spec path or name spec_validation, got: #{reason}"

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
