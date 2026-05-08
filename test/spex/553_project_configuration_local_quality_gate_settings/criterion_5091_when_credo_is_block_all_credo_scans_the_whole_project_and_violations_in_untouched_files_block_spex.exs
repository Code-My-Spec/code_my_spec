defmodule CodeMySpecSpex.Story553.Criterion5091Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5091 — When credo is set to block_all, the stop hook invokes
  `mix credo` against the whole project (no file path arguments) and any
  violation blocks the stop, even when the violation lives in a file the
  agent did not touch this turn.

  ## Test setup

  Two turns:

  1. credo `:off` while the agent seeds `lib/legacy_module.ex` (with a
     credo violation) and `lib/clean_module.ex` (no violations). The
     pipeline runs without credo, so no credo problems are persisted.
  2. credo flipped to `:block_all`. The agent edits `lib/clean_module.ex`
     only. The pipeline invokes `mix credo` project-wide; the cassette
     returns the violation in `lib/legacy_module.ex` (an untouched file)
     and the stop is blocked.

  ## Recording the cassette

  See `priv/knowledge/bdd/spex/recording_cassettes.md`. The block_all
  turn must record `mix credo suggest --format json --all
  --all-priorities --no-color` with NO trailing file paths.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @legacy_path "lib/legacy_module.ex"
  @clean_path "lib/clean_module.ex"
  @fixture_dir "test/fixtures/validation/pipeline_clean_credo"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sets credo to block_all" do
    scenario "credo scans the whole project and an untouched-file violation blocks the stop" do
      given_ :synced_context_component
      given_ :credo_available
      given_ :on_configuration_page

      given_ "credo starts off so the seed turn doesn't invoke it", context do
        context.config_live
        |> form("[data-test='configuration-form']", configuration: %{credo: "off"})
        |> render_submit()

        {:ok, context}
      end

      given_ "turn 1: legacy and clean files are seeded into the project",
             context do
        :ok = Environments.write_file(context.environment, @legacy_path, legacy_with_violation())
        :ok = Environments.write_file(context.environment, @clean_path, clean_module())

        _seed_response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{
            "test_output_files" => %{
              "compile" => fixture_path("compile.jsonl"),
              "exunit" => fixture_path("exunit.json"),
              "spex" => fixture_path("spex.jsonl")
            }
          })
          |> Phoenix.ConnTest.json_response(200)

        {:ok, context}
      end

      given_ "credo is flipped to block_all", context do
        context.config_live
        |> form("[data-test='configuration-form']", configuration: %{credo: "block_all"})
        |> render_submit()

        {:ok, context}
      end

      given_ "turn 2: only the clean file is edited", context do
        :ok = Environments.write_file(context.environment, @clean_path, clean_module_v2())
        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response =
          use_cmd_cassette "credo_block_all_project_scan", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "test_output_files" => %{
                "compile" => fixture_path("compile.jsonl"),
                "exunit" => fixture_path("exunit.json"),
                "spex" => fixture_path("spex.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked with the legacy_module.ex violation", context do
        assert context.response["decision"] == "block",
               "credo :block_all must block on project-wide violations, got: #{inspect(context.response)}"

        assert context.response["reason"] =~ ~r/credo/i,
               "block reason must mention credo, got: #{inspect(context.response["reason"])}"

        assert context.response["reason"] =~ @legacy_path,
               "block reason must reference the untouched legacy file, got: #{inspect(context.response["reason"])}"

        {:ok, context}
      end

      then_ "the Problems page surfaces the persisted credo violation", context do
        {:ok, _problems_live, html} =
          live(context.conn, ~p"/projects/#{context.project.name}/problems?filter=credo")

        assert html =~ "Problems",
               "Problems page must render"

        assert html =~ @legacy_path,
               "Problems page must list the persisted legacy_module.ex violation, got HTML missing path"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp legacy_with_violation do
    """
    defmodule LegacyModule do
      @moduledoc false

      def doSomething(x) do
        x + 1
      end
    end
    """
  end

  defp clean_module do
    """
    defmodule CleanModule do
      @moduledoc "A clean module with no credo violations."

      def add(a, b), do: a + b
    end
    """
  end

  defp clean_module_v2 do
    """
    defmodule CleanModule do
      @moduledoc "A clean module with no credo violations."

      def add(a, b), do: a + b

      def subtract(a, b), do: a - b
    end
    """
  end
end
