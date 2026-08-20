defmodule CodeMySpecSpex.Story1017.Criterion2415Spex do
  @moduledoc """
  Story 896 — Agent sees the questions it has open
  Criterion 2415 — A refusal carries the count of what is waiting on the user.

  The rule:

  > A stop that is refused says how many questions are open.

  ## What this adds to the menu

  Story 894 left `check_answer` as an unconditional offer with no count:

      If a question you asked has been answered, `check_answer` has the reply.

  That is enough to stop a *pending* question being forgotten only if the agent
  remembers it asked one. Across a compaction it does not, and the offer reads
  as boilerplate — it says the same thing whether nothing is waiting or three
  things are. A count is the difference between a standing offer and a fact
  about right now.

  Note what is *not* being claimed. The count rides a refusal caused by some
  other class; it never causes one. 2414 asserts that half, and the two have to
  be read together: this one alone is satisfied by a hook that blocks on
  questions, which is the failure 2414 exists to catch.

  ## Two questions, not one

  A count of one is indistinguishable from the singular wording of a boolean
  ("a question is open"), so a spec asserting one question passes against an
  implementation that cannot count. Two is the smallest number that forces a
  count to exist.

  ## Surface

  `POST /api/hooks/stop` on the local endpoint, refused by a genuine compile
  failure from story 555's `pipeline_compile_error` fixtures — the same lever
  2402 and 2403 use. Questions are asked through `POST /api/questions/ask` on
  the cloud endpoint, dispatched explicitly because `~p` here resolves against
  `CodeMySpecLocalWeb.Endpoint`.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.AskUser

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A refusal tells the agent how much is waiting on the user" do
    scenario "two questions are open and a problem refuses the stop" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "the agent asked the user two questions", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        ids =
          for text <- ["Which approach do you want here?", "Should this ship behind a flag?"] do
            {:reply, response, _frame} = AskUser.execute(%{message: text}, frame)

            refute response.isError,
                   "asking is the agent's own surface and has to work here. " <>
                     "Got: #{response_text(response)}"

            question_id!(response)
          end

        {:ok, Map.put(context, :question_ids, ids)}
      end

      given_ "a problem is outstanding, so the stop will be refused", context do
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

      then_ "the stop is refused, so there is a reason to inspect", context do
        assert context.response["decision"] == "block",
               "this scenario needs a refusal for the count to have somewhere to " <>
                 "ride. Got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the refusal says two questions are open", context do
        reason = context.response["reason"] || ""

        # Number and noun together, deliberately. A bare `2` is satisfied by any
        # other tally in the same refusal — problems and requirements both
        # print counts — so matching the digit alone would pass against an
        # implementation that never counts questions at all.
        assert reason =~ ~r/\b(2|two)\s+questions\b/i,
               "the agent asked two questions and neither is answered; a menu " <>
                 "that never says so is boilerplate the agent learns to skip. " <>
                 "Got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  # `ask_user` reports the id in prose, which is what the agent reads.
  defp question_id!(response) do
    body = response_text(response)

    captured!(Regex.run(~r/Question id: ([0-9a-f-]{36})/, body), body)
  end

  # Two heads rather than a `case`, following 958's `captured!/2`: imperative
  # `case` is banned in spex files, and a bare match would throw away the
  # haystack — `Regex.run/2` returns nil, so the MatchError says only "nil".
  defp captured!([_, id], _body), do: id
  defp captured!(_no_match, body), do: raise("could not read a question id from: #{body}")

  defp broken_impl do
    """
    defmodule ExampleContext do
      # missing `end`
    """
  end
end
