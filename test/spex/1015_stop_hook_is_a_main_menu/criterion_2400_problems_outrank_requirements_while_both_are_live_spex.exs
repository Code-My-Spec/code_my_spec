defmodule CodeMySpecSpex.Story1015.Criterion2400Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2400 — Problems outrank requirements while both are live.

  The rule:

  > Live classes are offered in a fixed order: problems before requirements.

  The order is the point, not the fact of ordering. An agent sent to
  `get_next_requirement` while findings are outstanding starts new work on top
  of a broken tree, and the findings stay outstanding — so "do the next thing"
  has to wait behind "fix what is already wrong".

  Both halves are asserted. Naming `list_problems` proves the tier fires;
  refuting `get_next_requirement` proves it *ranks* rather than listing
  everything, which is the failure mode a full menu has.

  ## Surface

  `POST /api/hooks/stop`, routed by `x-harness-id`. Story 555's
  `pipeline_compile_error` fixtures make the problem real; the synced component
  leaves requirements genuinely unsatisfied, so both classes are live rather
  than one being staged.

  Expected red: nothing ranks classes today, and nothing names a call at all.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Problems are offered before requirements" do
    scenario "both classes live, and the directive is the problem one" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "a problem is outstanding alongside unsatisfied requirements", context do
        :ok = Environments.write_file(context.environment, @impl_path, broken_impl())
        {:ok, context}
      end

      when_ "the agent attempts to stop", context do
        response =
          use_cmd_cassette "pipeline_compile_error", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{"compile" => fixture_path("compile.jsonl")}
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the directive is to fix the problems", context do
        reason = context.response["reason"] || ""

        assert reason =~ "list_problems",
               "problems are live and rank first, so they are what the agent is " <>
                 "sent to. Got:\n#{reason}"

        {:ok, context}
      end

      then_ "the agent is not sent to start new work", context do
        reason = context.response["reason"] || ""

        refute reason =~ "get_next_requirement",
               "requirements rank below problems, so offering both is not ordering " <>
                 "them — and an agent that takes the requirement starts new work on a " <>
                 "tree that is already broken. Got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp broken_impl do
    """
    defmodule ExampleContext do
      # missing `end`
    """
  end
end
