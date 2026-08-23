defmodule CodeMySpecSpex.Story553.Criterion6029Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 6029 — When credo is set to block_changed, the stop hook
  invokes `mix credo` only on the files the agent touched this turn (file
  paths passed as arguments). Violations in files outside the changed set
  are not surfaced and do not block the stop.

  This is the contrast case for criterion 5091. block_changed keeps the
  scoped-scan; block_all is the only mode that goes project-wide.

  ## Test setup

  Two turns:

  1. credo `:off` while the agent seeds `lib/legacy_module.ex` (with a
     credo violation) and `lib/clean_module.ex` (no violations). No
     credo problems persist.
  2. credo flipped to `:block_changed`. The agent edits
     `lib/clean_module.ex` only. The pipeline invokes `mix credo
     ... lib/clean_module.ex`; the cassette returns an empty `issues`
     list, no problems persist, and the stop is allowed.

  ## Recording the cassette

  The block_changed turn must record `mix credo suggest --format json
  --all --all-priorities --no-color lib/clean_module.ex` with the file
  path argument present, returning `{"issues":[]}`.
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

  spex "Engineer sets credo to block_changed" do
    scenario "credo runs only on the changed file and violations elsewhere do not block" do
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
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
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

      given_ "credo is flipped to block_changed", context do
        context.config_live
        |> form("[data-test='configuration-form']", configuration: %{credo: "block_changed"})
        |> render_submit()

        {:ok, context}
      end

      given_ "turn 2: only the clean file is edited", context do
        :ok = Environments.write_file(context.environment, @clean_path, clean_module_v2())
        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response =
          use_cmd_cassette "credo_block_changed_scoped_scan", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
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

      then_ "the stop is allowed because the changed file has no violations", context do
        assert context.response == %{},
               "credo :block_changed must allow when the changed file is clean, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the Problems page does not list any credo problem", context do
        {:ok, _problems_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/problems?filter=credo")

        assert html =~ "Problems"

        refute html =~ @legacy_path,
               "Problems page must NOT list the untouched legacy_module.ex violation under block_changed"

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
