defmodule CodeMySpecSpex.Story553.Criterion5087Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5087 — When an engineer turns off credo during a large refactor,
  credo violations do NOT block the stop hook response.

  End-to-end: mutates an implementation file with credo violations, fires the
  real stop hook endpoint, and verifies credo was skipped by the pipeline.
  System.cmd calls are replayed from the `credo_violation` cassette — whose
  credo entry would have blocked the response if the config filter were
  missing.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer turns off credo during a large refactor" do
    scenario "credo violations don't block the stop response" do
      given_ :synced_context_component
      given_ :on_configuration_page

      given_ "credo is turned off in the configuration", context do
        context.config_live
        |> form("[data-test='configuration-form']", configuration: %{credo: "off"})
        |> render_submit()

        {:ok, context}
      end

      given_ "the implementation file has been mutated with credo violations",
             context do
        :ok = Environments.write_file(context.environment, @impl_path, messy_impl())
        {:ok, context}
      end

      when_ "the stop hook fires", context do
        # No session_id — the stop controller skips TaskEvaluator when there
        # is no session, keeping this spec focused on the pipeline/config
        # interaction rather than requirement evaluation.
        response =
          use_cmd_cassette "credo_violation", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              # `spex_stale` runs whatever the `spex` config says — the config
              # only decides whether a failure blocks. Declaring the suite
              # green keeps it out of a spec about credo.
              "test_output_files" => %{
                "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop hook allows the stop without mentioning credo", context do
        reason = Map.get(context.response, "reason", "")

        refute reason =~ ~r/credo/i,
               "stop response must not mention credo when credo is off, got: #{inspect(context.response)}"

        # Credo off + clean compile + passing tests (from cassette) = no block.
        # Empty map is the allow signal the stop controller returns.
        assert context.response == %{},
               "expected allow response, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  # Implementation file with two credo violations (camelCase name + nested ifs).
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
