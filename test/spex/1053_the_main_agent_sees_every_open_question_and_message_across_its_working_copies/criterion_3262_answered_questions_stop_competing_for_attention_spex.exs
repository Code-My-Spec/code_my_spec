defmodule CodeMySpecSpex.Story1053.Criterion3262Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question and message across its
  working copies.
  Criterion 3262 — Answered questions stop competing for attention.

  Rule: the list is what is still waiting, not what has ever been asked.

  The counterweight to 3260 and 3261, and the one that decides whether this
  surface is usable rather than merely complete. Those two push everything into
  one list; without this the list only grows, and a main agent reading it has to
  work out for itself which entries still mean anything. A list that never
  shrinks is a list nobody reads, which returns the project to the state story
  1053 exists to leave — questions waiting where nobody is looking.

  The answer is given through `check_answer`'s own path rather than by writing a
  status, so that "answered" means what the product means by it. A criterion
  that flipped a field directly would pass against an implementation that
  filters on a field nothing ever sets.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "What is waiting is what is still unanswered" do
    scenario "one of two questions has been answered" do
      given_ "two agents with a question each, and one of them answered",
             context do
        reply = join_working_copy(context, "/tmp/spex-3262", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        asked =
          for role <- ["coding", "qa"] do
            agent =
              CodeMySpecSpex.Fixtures.running_agent(scope,
                role: role,
                working_copy: "/tmp/spex-3262"
              )

            frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

            {:reply, response, _frame} =
              AskUserQuestion.execute(
                %{
                  title: "#{role} needs a decision",
                  questions: [
                    %{
                      "question" => "Which way should #{role} go?",
                      "options" => [%{"label" => "A"}, %{"label" => "B"}]
                    }
                  ]
                },
                frame
              )

            refute response.isError, inspect(response)

            {role, response_text(response)}
          end

        # Answered the way the user answers, so that "answered" means what the
        # product means rather than what a field happens to hold. Writing the
        # status here would let a listing that filters on something nothing sets
        # pass this criterion.
        {"coding", coding_response} = List.keyfind(asked, "coding", 0)
        question_id = CodeMySpecSpex.Fixtures.question_id_from(coding_response)
        :ok = CodeMySpecSpex.Fixtures.answer_question(scope, question_id, "A")

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:answered_id, question_id)}
      end

      when_ "the main agent looks at what is waiting", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListNotifications.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :listing, response_text(response))}
      end

      then_ "only the unanswered one is listed", context do
        assert context.listing =~ "Which way should qa go?",
               """
               The unanswered question is missing.

               listing:
               #{context.listing}
               """

        refute context.listing =~ "Which way should coding go?",
               """
               An answered question is still listed as waiting.

               A list that only grows is a list nobody reads, and the main agent
               then works out for itself which entries still mean something —
               which is the job this surface exists to do for it. Every answered
               question left in place makes the next real one harder to see.

               listing:
               #{context.listing}
               """

        {:ok, context}
      end
    end
  end
end
