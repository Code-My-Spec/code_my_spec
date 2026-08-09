defmodule CodeMySpecSpex.Story553.Criterion5108Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5108 — When spec_validation is set to off, the spec
  validator does not run during the stop hook and no spec_validation
  problems are persisted. The stop is allowed.

  Mirrors 5087 (credo off) for the spec_validation source.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @broken_spec_path ".code_my_spec/spec/todo/broken.spec.md"
  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sets spec_validation to off" do
    scenario "spec validation does not run and the stop is allowed" do
      given_ :synced_context_component
      given_ :on_configuration_page

      given_ "spec_validation is set to off", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{spec_validation: "off"}
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

      then_ "the stop is allowed", context do
        assert context.response == %{},
               "spec_validation off must allow stop, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "no spec_validation problems appear on the problems page", context do
        {:ok, problems_live, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/problems?filter=spec_validation"
          )

        html = render(problems_live)

        assert html =~ "data-test=\"problems-filters\"",
               "expected the problems page to render its filters anchor"

        refute html =~ "data-problem-source=\"spec_validation\"",
               "expected zero spec_validation problem rows, got: #{html}"

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
