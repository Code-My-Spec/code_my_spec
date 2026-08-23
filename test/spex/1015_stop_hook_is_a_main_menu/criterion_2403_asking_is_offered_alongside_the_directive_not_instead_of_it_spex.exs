defmodule CodeMySpecSpex.Story1015.Criterion2403Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2403 — Asking is offered alongside the directive, not instead of it.

  The rule:

  > Every refusal offers asking the user, because needing input is not a state
  > the hook can detect.

  This is the criterion that corrects the story's original mistake, so it is
  worth saying what the mistake was. The first pass had a rule reading "Input
  owed by the user is a class of available work", with a scenario beginning
  "Given the agent has work it cannot proceed on without a decision from the
  user". Nothing can evaluate that Given. Wanting to ask is an intention, and
  the hook has no access to intentions — only to rows.

  So needing input is not a class and never gets a tier. It is a line the hook
  always prints, and the only thing that can act on it is the agent reading it
  and recognising its own situation. John: "I don't think that you can know that
  the model wants to ask the user a question."

  Hence *alongside*. The offer sits next to whatever the directive happens to
  be — here, a problem — rather than competing with it. A response that dropped
  the offer whenever something else was live would be the detector all over
  again, just with the condition inverted.

  `ask_user` and `check_answer` are deliberately never the same rule: asking is
  the standing offer, collecting an answer is a tiered directive, because asking
  wrote a row and wanting to ask did not.

  ## Surface

  `POST /api/hooks/stop`, routed by `x-harness-id`, with a genuine problem from
  story 555's `pipeline_compile_error` fixtures.

  Expected red: today the only tool call any refusal names is `create_issue`, in
  the harness-friction footer — the escape hatch rather than the work.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The offer to ask survives a directive about something else" do
    scenario "problems are the live class and no question is pending" do
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

      then_ "asking the user is offered as well", context do
        reason = context.response["reason"] || ""

        assert reason =~ "ask_user",
               "the hook cannot detect that the agent needs input, so it says so " <>
                 "every time rather than waiting for a condition it cannot evaluate. " <>
                 "Dropping the offer because something else is live rebuilds the " <>
                 "detector with the condition inverted. Got:\n#{reason}"

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
