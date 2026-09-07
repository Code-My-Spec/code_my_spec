defmodule CodeMySpecSpex.Story553.Criterion6071Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 6071 — When spec_validation is block_changed (the default),
  spec_validation problems persisted from prior turns do not block the
  stop when the agent did not modify those spec files this turn.

  End-to-end: two turns of the stop hook.

  Turn 1 writes a spec file missing required sections. The pipeline runs
  the spec validator on the changed file and records a spec_validation
  problem. Turn 2 fires the stop hook with no file changes — FileSync
  reports nothing, the pipeline is skipped, and `check_blocking_problems`
  consults the persisted problem with `block_changed` config and empty
  `changed_file_paths`, demoting it to advisory.

  We only assert on turn 2; turn 1 is setup.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @broken_spec_path ".code_my_spec/spec/todo/broken.spec.md"
  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer leaves spec_validation at default block_changed" do
    scenario "stub spec files in the DB don't block turns that didn't touch them" do
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

      given_ "turn 1: the agent writes a broken spec file and fires the stop hook",
             context do
        :ok =
          Environments.write_file(
            context.environment,
            @broken_spec_path,
            broken_spec()
          )

        _turn_1_response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "test_output_files" => %{
                "compile" => fixture_path("compile.jsonl"),
                "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, context}
      end

      when_ "turn 2: the stop hook fires with no file changes", context do
        # Second turn: no writes since turn 1, so FileSync reports no
        # changes and compiler/credo/exunit are memoized. `spex_stale`
        # is not — it re-enqueues a real recursive `mix spex` on every
        # stop regardless of fingerprint — so this still needs a
        # cassette to stay off a real subprocess.
        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "test_output_files" => %{
                "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed because the broken spec is outside task scope",
            context do
        assert context.response == %{},
               "block_changed must treat untouched spec_validation problems as advisory, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  # Missing required sections (fields / functions / components). The
  # document schema rejects this content; the validator records a
  # spec_validation problem against this file_path.
  defp broken_spec do
    """
    # Todo.Broken

    A stub spec that hasn't been filled in yet.
    """
  end
end
