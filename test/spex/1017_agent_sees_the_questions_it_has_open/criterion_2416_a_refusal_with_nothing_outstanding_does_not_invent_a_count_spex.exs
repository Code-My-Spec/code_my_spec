defmodule CodeMySpecSpex.Story1017.Criterion2416Spex do
  @moduledoc """
  Story 896 — Agent sees the questions it has open
  Criterion 2416 — A refusal with nothing outstanding does not invent a count.

  The rule:

  > A stop that is refused says how many questions are open.

  The negative half of 2415, and the reason that rule is safe to implement.

  ## Why the pair is needed

  2415 asserts a refusal carrying "2 questions" when two are open. On its own it
  is satisfied by an implementation that prints a count unconditionally —
  including "0 questions" on every refusal, forever. That is not a smaller bug
  than omitting the count: a line that appears on every stop and is almost
  always zero is exactly the boilerplate 894 spent its whole design avoiding,
  and it costs the same attention as a real directive.

  So this scenario opens no questions at all and asserts the refusal says
  nothing about them. What survives both is a count that appears when there is
  something to count.

  ## What "does not invent" means precisely

  Not that the word "question" is absent. `check_answer`'s standing offer is
  unconditional by 894/2402 and mentions a question by necessity:

      If a question you asked has been answered, `check_answer` has the reply.

  That offer must remain — asserting its absence would put this criterion in
  direct conflict with 2402. What must be absent is a *count*: a number
  attached to questions, claiming state that does not exist.

  ## Surface

  `POST /api/hooks/stop`, refused by the same `pipeline_compile_error` fixture
  2415 uses, so the two differ in exactly one thing: whether any question was
  asked.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A refusal claims no questions when none are open" do
    scenario "nothing was ever asked and a problem refuses the stop" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "a problem is outstanding, so the stop will be refused", context do
        # No question is asked anywhere in this scenario, and that absence is
        # the scenario.
        :ok = Environments.write_file(context.environment, @impl_path, broken_impl())
        :ok = record_edit(context, @impl_path)
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

      then_ "the stop is refused, so the refutation has something to inspect", context do
        assert context.response["decision"] == "block",
               "without a refusal the refutation below passes against an empty " <>
                 "string and proves nothing. Got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "no count of open questions appears", context do
        reason = context.response["reason"] || ""

        refute reason =~ ~r/\b\d+\s+questions?\b/i,
               "nothing was asked, so any number attached to questions is a " <>
                 "claim about state that does not exist — and a count printed " <>
                 "unconditionally is the boilerplate a menu cannot afford. " <>
                 "Got:\n#{reason}"

        {:ok, context}
      end

      then_ "the standing offer to collect an answer survives", context do
        # Proves the refutation above is about the count specifically. Asserting
        # the word "question" were absent would contradict 894/2402, which makes
        # this offer unconditional on purpose.
        reason = context.response["reason"] || ""

        assert reason =~ "check_answer",
               "the offer is unconditional by 2402; removing it is not the way " <>
                 "to satisfy this criterion. Got:\n#{reason}"

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
