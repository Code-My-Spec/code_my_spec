defmodule CodeMySpecSpex.Story1085.Criterion1734Spex do
  @moduledoc """
  Story 1085 — I'm told where my code has drifted from the plan
  Criterion 1734 — Block changed blocks only drift on touched components.

  Same shortcut as criterion 1733: the architecture findings are seeded
  directly via `Fixtures.problem_fixture/2` rather than produced by the
  checker, because this criterion is about the stop hook's per-component
  `block_changed` scoping (the same generic mechanism criterion 118
  already proves for exunit), not about how an architecture finding is
  produced.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.ComponentGraphHelpers
  alias CodeMySpecSpex.Fixtures

  @billing_path "lib/billing.ex"
  @reports_path "lib/reports.ex"
  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Block changed blocks only drift on touched components", criterion: 1734 do
    scenario "only the touched component's drift blocks the stop" do
      given_ :on_configuration_page

      given_ "Sam set architecture to block changed", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{architecture: "block_changed"}
        )
        |> render_submit()

        {:ok, context}
      end

      given_ "drift exists on Billing and on Reports", context do
        app = ComponentGraphHelpers.app(context)

        billing = ComponentGraphHelpers.design!(context, "#{app}.Billing")
        reports = ComponentGraphHelpers.design!(context, "#{app}.Reports")

        :ok =
          Environments.write_file(context.environment, @billing_path, """
          defmodule #{app}.Billing do
            @moduledoc false
          end
          """)

        :ok =
          Environments.write_file(context.environment, @reports_path, """
          defmodule #{app}.Reports do
            @moduledoc false
          end
          """)

        Fixtures.problem_fixture(context.scope, %{
          source: "architecture",
          file_path: @billing_path,
          component_id: billing.id,
          line: 1,
          message: "Billing drift finding",
          category: "unplanned_dependency",
          rule: nil
        })

        Fixtures.problem_fixture(context.scope, %{
          source: "architecture",
          file_path: @reports_path,
          component_id: reports.id,
          line: 1,
          message: "Reports drift finding",
          category: "no_code",
          rule: nil
        })

        {:ok, context |> Map.put(:billing, billing) |> Map.put(:reports, reports)}
      end

      given_ "a session starts work on the project", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "an agent finishes a change touching only Billing", context do
        app = ComponentGraphHelpers.app(context)

        :ok =
          Environments.write_file(context.environment, @billing_path, """
          defmodule #{app}.Billing do
            @moduledoc false
            def noop, do: :ok
          end
          """)

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/post-tool-use", %{
          "session_id" => context.session_id,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => @billing_path}
        })
        |> Phoenix.ConnTest.json_response(200)

        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
                "exunit" => fixture_path("exunit.json"),
                "compile" => fixture_path("compile.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the agent is blocked on the Billing drift", context do
        assert context.response["decision"] == "block",
               "expected Billing's drift to block the stop, got: #{inspect(context.response)}"

        assert context.response["reason"] =~ "Billing drift finding",
               "expected the block reason to name Billing's finding, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "not on the Reports drift", context do
        refute context.response["reason"] =~ "Reports drift finding",
               "expected Reports' untouched drift to be advisory, not in the block reason, got: " <>
                 inspect(context.response)

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
