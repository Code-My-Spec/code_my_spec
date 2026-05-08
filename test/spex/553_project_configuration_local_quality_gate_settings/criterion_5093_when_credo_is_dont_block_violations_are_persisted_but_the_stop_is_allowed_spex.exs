defmodule CodeMySpecSpex.Story553.Criterion5093Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5093 — When credo is set to dont_block, the stop hook still
  runs credo against the changed files and persists any violations as
  problems, but the stop is allowed regardless. The engineer can confirm
  what was found by visiting the Problems page.

  Mirrors the exunit `:dont_block` scenario (5089) for credo.

  ## Recording the cassette

  Single turn: agent edits `lib/example_context.ex` with credo
  violations. The cassette captures `mix credo suggest --format json
  --all --all-priorities --no-color lib/example_context.ex` returning
  the violations.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_clean_credo"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sets credo to dont_block" do
    scenario "credo violations are persisted but the stop is allowed" do
      given_ :synced_context_component
      given_ :credo_available
      given_ :on_configuration_page

      given_ "credo is set to dont_block", context do
        context.config_live
        |> form("[data-test='configuration-form']", configuration: %{credo: "dont_block"})
        |> render_submit()

        {:ok, context}
      end

      given_ "the agent edits an implementation file with a credo violation",
             context do
        :ok = Environments.write_file(context.environment, @impl_path, messy_impl())
        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response =
          use_cmd_cassette "credo_dont_block", record: :none do
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

      then_ "the stop is allowed without referencing credo as blocking", context do
        assert context.response == %{},
               "credo :dont_block must allow despite violations, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the Problems page surfaces the persisted credo violation", context do
        {:ok, _problems_live, html} =
          live(context.conn, ~p"/projects/#{context.project.name}/problems?filter=credo")

        assert html =~ "Problems"

        assert html =~ @impl_path,
               "Problems page must list the persisted example_context.ex violation, got HTML missing path"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp messy_impl do
    """
    defmodule ExampleContext do
      @moduledoc false

      def doSomething(x) do
        if x == true do
          IO.puts("yes")
        else
          if x == false do
            IO.puts("no")
          else
            IO.puts("maybe")
          end
        end
      end
    end
    """
  end
end
