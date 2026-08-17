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

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A refusal tells the agent how much is waiting on the user" do
    scenario "two questions are open and a problem refuses the stop" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "the agent asked the user two questions", context do
        context =
          context
          |> ask_question("Which approach do you want here?")
          |> ask_question("Should this ship behind a flag?")

        {:ok, context}
      end

      given_ "a problem is outstanding, so the stop will be refused", context do
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

  # The real path an unattended agent's question takes: the cloud endpoint,
  # behind `DeployKeyOrOAuth`. Reused across calls, so the deploy key is issued
  # once and only when absent.
  defp ask_question(context, text) do
    key = context[:deploy_key] || issue_deploy_key(context)

    %{"id" => id} =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{key}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Phoenix.ConnTest.dispatch(CodeMySpecWeb.Endpoint, :post, "/api/questions/ask", %{
        "questions" => [
          %{"question" => text, "header" => nil, "multiSelect" => false, "options" => []}
        ],
        "title" => "Claude has a message",
        "harness_id" => context.scope.active_harness_id
      })
      |> Phoenix.ConnTest.json_response(201)

    context
    |> Map.put(:deploy_key, key)
    |> Map.update(:question_ids, [id], &(&1 ++ [id]))
  end

  defp issue_deploy_key(context) do
    key = "spex-deploy-key-#{System.unique_integer([:positive])}"
    Fixtures.project_with_deploy_key(context.scope, context.project, key)
    key
  end

  defp broken_impl do
    """
    defmodule ExampleContext do
      # missing `end`
    """
  end
end
