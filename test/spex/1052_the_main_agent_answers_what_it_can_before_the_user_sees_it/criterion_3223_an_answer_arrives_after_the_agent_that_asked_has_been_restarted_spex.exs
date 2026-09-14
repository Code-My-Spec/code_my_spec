defmodule CodeMySpecSpex.Story1052.Criterion3223Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 3223 — An answer arrives after the agent that asked has been
  restarted.

  The gap this closes is made by the design working correctly. `ask_user` and
  `check_answer` are deliberately two steps — an agent raises a question and
  collects whenever it gets round to it, because answering takes as long as a
  person takes. A wait measured in hours guarantees that some of those agents
  will not be the same process by the time the answer lands.

  `list_user_questions` already carries the reasoning for why: an agent's own
  record of what it asked is the thing a compaction destroys, and without a
  listing "a question raised before the context was summarised is simply lost:
  never collected, never re-asked, and the work that prompted it quietly
  proceeds without the answer." A restart is that, harder — not a summarised
  context but a new process.

  So the answer has to outlive the asker. "Available to that agent rather than
  discarded with the process" is the whole claim: the question is keyed on
  something durable, not on a pid, a session, or anything else the restart
  takes with it.

  Driven through a real restart rather than by asserting on a row, because what
  breaks is the relationship between the answer and an agent that is no longer
  the process that asked.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.QuestionRoutingHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An answer outlives the process that asked for it" do
    scenario "An answer arrives after the agent that asked has been restarted" do
      given_ "an agent that asked a question", context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :zai)
        agent = Fixtures.running_agent(context.scope, role: "coding")

        id =
          ask(context, "Should refunds older than ninety days be allowed?", ["Allow", "Refuse"])

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:question_id, id)}
      end

      given_ "and was then restarted", context do
        {:reply, reply, _frame} =
          RestartAgent.execute(
            %{agent_id: context.agent.id, reason: "it stopped answering"},
            frame(context)
          )

        refute reply.isError,
               "the premise is an agent that was restarted:\n#{response_text(reply)}"

        {:ok, context}
      end

      when_ "the answer arrives", context do
        :ok = user_answers(context, context.question_id, "Refuse")

        {:ok, Map.put(context, :answer, collect(context, context.question_id))}
      end

      then_ "the answer is not lost", context do
        refute context.answer =~ ~r/(not found|no such question|unknown question)/i,
               """
               The question went with the process that asked it.

               `ask_user` and `check_answer` are two steps on purpose, because
               answering takes as long as a person takes — and a wait measured
               in hours guarantees some askers will not be the same process
               when the answer lands.

               #{context.answer}
               """

        {:ok, context}
      end

      then_ "and it is available to that agent rather than discarded with the process",
            context do
        assert context.answer =~ "Refuse",
               """
               The answer exists and the restarted agent cannot read it.

               `list_user_questions` already records what this costs: a
               question the asker loses track of is "never collected, never
               re-asked, and the work that prompted it quietly proceeds without
               the answer". A restart is that failure with a new process rather
               than a summarised context.

               The question has to be keyed on something the restart does not
               take — not a pid, not a session.

               #{context.answer}
               """

        {:ok, context}
      end
    end
  end
end
