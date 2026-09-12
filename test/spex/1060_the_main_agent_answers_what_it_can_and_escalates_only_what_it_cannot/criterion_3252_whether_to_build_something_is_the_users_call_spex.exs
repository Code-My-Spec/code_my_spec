defmodule CodeMySpecSpex.Story1060.Criterion3252Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 3252 — Whether to build something is the user's call.

  Rule: the main agent decides what is true, never what is wanted.

  3251's boundary from the other side, and the one that keeps this story from
  being a licence. A main agent with a wide reach and an instruction to spare
  the user is under steady pressure to answer everything — and "should we build
  this" is answerable-looking: the project's records say the feature does not
  exist, the roadmap implies an order, and a confident reply is one sentence
  away.

  Every one of those is evidence about the *state* of the project. None of them
  is the decision, and the difference is not visible in the answer's text. That
  is what the basis is for: `record` says the project records this, and no
  record says what somebody wants built next.

  ## The cost of getting it wrong

  A feature built because an agent inferred it was wanted is worse than one not
  built. The user finds out by reading a changelog, the work is already spent,
  and the next thing they do is stop trusting anything the fleet decides — which
  costs the whole arrangement, not just the feature.

  ## Both halves

  Refused, *and* the question reaches the user. A main agent that declined to
  answer and left the question sitting with itself has spared the user an
  interruption by silently dropping their decision, which is the same outcome as
  deciding it badly except that nothing happens at all.

  ## "Reached the user" is the holder, not the inbox

  The notifications inbox lists every question pending for the person whatever
  its holder is, so finding the text there says only that somebody asked —
  which was true before the main agent did anything. What the criterion is
  about is who holds it now, and story 1053 already built the vocabulary:
  `list_open_questions` says `waiting on the user` when it has been passed up.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerQuestion
  alias CodeMySpec.McpServers.MainAgent.Tools.ListOpenQuestions
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @question "Should we build dunning emails now, or leave them for later?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "What to build is not the main agent's to settle" do
    scenario "a coding agent asks whether an unbuilt feature should be built" do
      given_ "an agent asking whether to build something", context do
        reply = join_working_copy(context, "/tmp/spex-3252", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3252")

        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "a decision about the product",
              questions: [
                %{
                  "question" => @question,
                  "options" => [%{"label" => "Now"}, %{"label" => "Later"}]
                }
              ]
            },
            asking
          )

        refute asked.isError, inspect(asked)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "the main agent handles the question", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AnswerQuestion.execute(
            %{
              question_id: context.question_id,
              answer: "Later — nothing in the roadmap puts it before the exporter",
              basis: "record"
            },
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it does not decide on the user's behalf", context do
        assert context.response.isError,
               """
               The main agent decided what to build.

               "Should we build this" is answerable-looking: the records say the
               feature does not exist, the roadmap implies an order, and a
               confident reply is one sentence away. Every one of those is
               evidence about the *state* of the project and none of them is the
               decision.

               A feature built because an agent inferred it was wanted is worse
               than one not built — the user finds out from a changelog, the
               work is spent, and the next thing they do is stop trusting
               anything the fleet decides.

               reply:
               #{response_text(context.response)}
               """

        {:ok, context}
      end

      then_ "and the question reaches the user", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListOpenQuestions.execute(%{}, frame)

        assert response_text(listing) =~ ~r/waiting on the user/i,
               """
               The main agent declined to answer and the user never heard about
               it either.

               Sparing them an interruption by silently dropping their decision
               is the same outcome as deciding it badly, except that nothing
               happens at all and the agent that asked waits forever.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
