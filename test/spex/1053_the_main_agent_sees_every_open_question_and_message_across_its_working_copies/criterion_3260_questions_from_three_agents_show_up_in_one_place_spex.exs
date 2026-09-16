defmodule CodeMySpecSpex.Story1053.Criterion3260Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question and message across its
  working copies.
  Criterion 3260 — Questions from three agents show up in one place.

  The first spex on this story, so it chooses the surface the rest inherit.
  Written down because the choice is a design decision and the module it names
  does not exist yet: what is written here becomes the public API.

  ## Why an MCP tool

  The main agent is an agent. It acts through tools, not through a page — the
  page is for the person it reports to, and story 1053's criteria are about what
  the *main agent* can see. Criterion 3267 is the exception and is deliberately
  the user's view of the same thing; it belongs on the notifications LiveView
  and is written that way.

  `CodeMySpec.McpServers.MainAgent.Tools.ListNotifications` is a new tool in a
  new server. Two existing ones were considered and rejected:

    * `Tasks.Tools.ListUserQuestions` answers "what have **I** asked", scoped to
      the calling session, and says so at length in its own moduledoc — session
      scope is deliberate there, to stop one worktree acting on another's
      question. This criterion needs the opposite: everything asked *by* the
      agents of one project, whoever asked it.

    * `Agents.Tools.ListAgents` answers which agents exist. Hanging questions off
      it would make a listing tool answer two questions and force every caller
      that wants one to pay for the other.

  ## What the criterion demands that today's model does not carry

  `Notifications.create_question_request/2` keys a question to a **user**. This
  criterion asks for questions attributed to the **agent** that raised them, and
  criterion 3266 adds the project and working copy. So the tool cannot be a view
  over the existing shape alone — the attribution has to exist. That is the
  point of writing it red.

  Questions are raised here the way an agent raises one: `AskUserQuestion`
  executed on each agent's own scope. Seeding rows directly would prove the
  listing works on data nobody could have produced, and the attribution this
  criterion turns on is exactly what the real call path supplies.
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

  # The join runs in a channel process of its own.
  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "One place shows what every agent is waiting on" do
    scenario "three agents of different kinds each have a question open" do
      given_ "a coding, a QA and a product agent each with an open question",
             context do
        reply = join_working_copy(context, "/tmp/spex-3260", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agents =
          for role <- ["coding", "qa", "product"] do
            agent =
              CodeMySpecSpex.Fixtures.running_agent(scope,
                role: role,
                working_copy: "/tmp/spex-3260"
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

            refute response.isError, "#{role} could not ask its question: #{inspect(response)}"

            {role, agent}
          end

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agents, agents)}
      end

      when_ "the main agent looks at what is waiting", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListNotifications.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :listing, response_text(response))}
      end

      then_ "all three are listed, each naming the agent that asked", context do
        for {role, agent} <- context.agents do
          assert context.listing =~ "Which way should #{role} go?",
                 """
                 The #{role} agent's question is not in the listing.

                 One place showing what every agent is waiting on is the whole
                 of this story: a main agent that has to ask each agent in turn
                 learns about a blocked one only by going and looking, which is
                 the thing it is supposed to spare the user.

                 listing:
                 #{context.listing}
                 """

          assert context.listing =~ agent.id,
                 """
                 The #{role} agent's question does not say which agent asked it.

                 A list of questions with no asker is a list the main agent
                 cannot act on — it can see that something is waiting and not
                 who is waiting, so it can neither answer the agent nor tell the
                 user whose work is stopped.

                 listing:
                 #{context.listing}
                 """
        end

        {:ok, context}
      end
    end
  end
end
