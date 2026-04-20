defmodule CodeMySpecSpex.Story555.Criterion5100Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors
  Criterion 5100 — When credo finds violations on files changed
  during the task, the stop hook blocks with the credo problems
  listed.

  The setup_active_project stub dir has only `mix.exs`, so
  `Credo.available?/1` normally returns false and the analyzer
  silently no-ops. The `:credo_available` shared given plants an
  empty `deps/credo` directory to flip availability on, then the
  cassette `pipeline_credo_blocks.json` replays the real
  `mix credo suggest` invocation with a JSON issue on
  `lib/example_context.ex`. The default config has
  `credo: :block_changed`, and the synced impl file is in the
  changed set — so the credo problem blocks.

  Fixtures:
  - `test/fixtures/cassettes/pipeline_credo_blocks.json` — compile
    clean, test clean, credo with one ModuleDoc violation.
  - `test/fixtures/validation/pipeline_credo_blocks/compile.jsonl` —
    empty (clean compile diagnostics).
  - `test/fixtures/validation/pipeline_credo_blocks/exunit.json` —
    zero failures.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  @fixture_dir "test/fixtures/validation/pipeline_credo_blocks"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Credo violations on changed files block the stop" do
    scenario "credo finds a moduledoc issue on impl, stop blocked with credo listed" do
      given_ :synced_context_component
      given_ :credo_available

      given_ "a session has a main_agent active task", context do
        external_id = "spex-#{System.unique_integer([:positive])}"

        session =
          Fixtures.session_with_task_fixture(
            context.scope,
            %{external_conversation_id: external_id},
            %{}
          )

        {:ok, Map.merge(context, %{session: session, external_id: external_id})}
      end

      when_ "the stop hook fires", context do
        response =
          use_cmd_cassette "pipeline_credo_blocks", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.external_id,
              "test_output_files" => %{
                "compile" => fixture_path("compile.jsonl"),
                "exunit" => fixture_path("exunit.json")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked with credo problems listed", context do
        assert context.response["decision"] == "block",
               "credo violation on changed file must block, got: #{inspect(context.response)}"

        reason = context.response["reason"]

        assert is_binary(reason)

        assert reason =~ ~r/\bcredo\b/i,
               "reason must mention credo, got:\n#{reason}"

        assert reason =~ "lib/example_context.ex",
               "reason must reference the offending file, got:\n#{reason}"

        assert reason =~ "Modules should have a @moduledoc tag",
               "reason must include the credo message, got:\n#{reason}"

        :ok
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
