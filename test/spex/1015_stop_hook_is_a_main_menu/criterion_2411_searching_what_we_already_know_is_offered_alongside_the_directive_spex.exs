defmodule CodeMySpecSpex.Story1015.Criterion2411Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2411 — Searching what we already know is offered alongside the
  directive.

  The rule:

  > Every refusal offers searching the project's own documentation, because the
  > hook cannot tell when the agent is missing something it already has.

  The second standing offer, and it exists because John remembered a reason
  agents stop that the first pass missed entirely: not that work is outstanding,
  but that the agent is short of information — information the project very
  often already holds. Framework reference, this project's own research and
  decisions, the specs and rules, all searchable, and an agent that does not
  think to look reasons from nothing and produces confident nonsense.

  That failure costs more than anything in the class list. A red test announces
  itself; a fluent wrong answer does not.

  ## Why an offer and not a class

  Same reason `ask_user` is one. No query answers "is this agent missing
  something it could look up" — wanting to know is an intention, and the hook
  sees rows. A first pass at this story made needing-input a class and produced
  a Given nothing could evaluate; this would fail the same way for the same
  reason.

  ## Why it is never withdrawn

  `ask_user` steps aside while a question is outstanding, because asking twice
  fills a queue with duplicates and that is a real harm. There is no equivalent
  harm in searching twice, and the case for looking is strongest exactly when
  the agent is stuck enough to be stopping. So this one has no exception, which
  is asserted below rather than assumed.

  ## Surface

  `POST /api/hooks/stop`, routed by `x-harness-id`, with a genuine compile
  failure from story 555's `pipeline_compile_error` fixtures. The offer rides a
  refusal like everything else in the menu — nothing on the allow path reaches
  the model.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The agent is reminded that the answer may already be written down" do
    scenario "problems are the live class and the documentation offer rides along" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "a problem is outstanding", context do
        :ok = Environments.write_file(context.environment, @impl_path, broken_impl())
        :ok = record_edit(context, @impl_path)
        {:ok, context}
      end

      when_ "the agent attempts to stop", context do
        response =
          use_cmd_cassette "pipeline_compile_error", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{"compile" => fixture_path("compile.jsonl")}
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the directive is still the problem one", context do
        reason = context.response["reason"] || ""

        assert reason =~ "list_problems",
               "the offer is additional to the directive, so the directive must " <>
                 "still be there. Got:\n#{reason}"

        {:ok, context}
      end

      then_ "searching the project's documentation is offered", context do
        reason = context.response["reason"] || ""

        assert reason =~ "semantic_search",
               "an agent short of information is a reason to stop that nothing " <>
                 "here can detect, so the remedy is named every time rather than " <>
                 "waiting for a condition that cannot be evaluated. Got:\n#{reason}"

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
