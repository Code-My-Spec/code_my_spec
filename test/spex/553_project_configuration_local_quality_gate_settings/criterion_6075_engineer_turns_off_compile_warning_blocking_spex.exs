defmodule CodeMySpecSpex.Story553.Criterion6075Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 6075 — When the engineer flips compile_warnings from the
  default `:block` to `:dont_block`, compiler warnings stop blocking
  the stop hook.

  The criterion's "But compiler errors still block" clause is a property
  of the compile step short-circuiting before the blocking check ever
  consults compile_warnings (see `Pipeline.compile/2`) — already covered
  by 5099 / 6077. This spex tests only the unique branch: the warning
  path through `partition_compiler/2`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  @fixture_dir "test/fixtures/validation/pipeline_compile_warning"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer turns off compile warning blocking" do
    scenario "compile warnings become advisory when compile_warnings is dont_block" do
      given_ :synced_context_component
      given_ :on_configuration_page

      given_ "compile_warnings is flipped to dont_block", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{compile_warnings: "dont_block"}
        )
        |> render_submit()

        {:ok, context}
      end

      when_ "the stop hook fires with a warning in the compile output", context do
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

      then_ "the stop is allowed", context do
        assert context.response == %{},
               "compile_warnings :dont_block must allow stop on warnings, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
