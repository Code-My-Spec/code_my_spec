defmodule CodeMySpecSpex.Story1053.Criterion3266Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question and message across its
  working copies.
  Criterion 3266 — A question carries who asked it and from where.

  Rule: a question is attributed to the agent that raised it, and the project
  and checkout follow from that agent.

  This is the criterion the others rest on, and the one that says the current
  data model is not enough. `Notifications.create_question_request/2` keys a
  question to a **user**: the shape is "Claude Code has a question for you". Every
  other criterion on this story assumes something else — that a question belongs
  to an agent, on a checkout, in a project — and none of them can be satisfied
  by filtering the existing shape, because the attribution is not in it.

  So this is written against the attribution rather than the listing, and it is
  where the implementation starts.

  Note what the criterion does *not* ask for. The working copy is not a field
  the asker supplies; it "follows from that agent", because an agent already
  belongs to exactly one checkout. Asking the caller for it would let a question
  name a copy its agent is not on, which is a way of being wrong that cannot
  happen if it is derived. Two agents on two checkouts of one project make that
  difference observable, which is why the scenario needs both.
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

  spex "A question says who asked and from which checkout" do
    scenario "two checkouts of one project are running agents" do
      given_ "an agent on each of two checkouts of the same project", context do
        [here, there] =
          for {root, label} <- [{"/tmp/spex-3266-a", "here"}, {"/tmp/spex-3266-b", "there"}] do
            reply = join_working_copy(context, root, label)
            scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

            agent =
              CodeMySpecSpex.Fixtures.running_agent(scope, role: "coding", working_copy: root)

            %{label: label, scope: scope, agent: agent, working_copy_id: reply.working_copy_id}
          end

        {:ok, context |> Map.put(:here, here) |> Map.put(:there, there)}
      end

      when_ "one of them asks a question", context do
        frame = %Frame{
          assigns: %{current_scope: context.there.scope, agent_id: context.there.agent.id}
        }

        {:reply, response, _frame} =
          AskUserQuestion.execute(
            %{
              title: "asked from the second checkout",
              questions: [
                %{
                  "question" => "Which branch should this land on?",
                  "options" => [%{"label" => "main"}, %{"label" => "a branch"}]
                }
              ]
            },
            frame
          )

        refute response.isError, inspect(response)

        {:ok, context}
      end

      then_ "it names that agent, its checkout, and this project", context do
        frame = %Frame{assigns: %{current_scope: context.here.scope}}
        {:reply, response, _frame} = ListNotifications.execute(%{}, frame)

        refute response.isError, inspect(response)
        listing = response_text(response)

        assert listing =~ "Which branch should this land on?",
               "the question is not listed at all:\n#{listing}"

        assert listing =~ context.there.agent.id,
               """
               The question does not name the agent that asked it.

               Without it the main agent can see that something is waiting and
               not who is waiting, so it can neither answer the agent nor tell
               the user whose work has stopped.

               listing:
               #{listing}
               """

        assert listing =~ context.there.working_copy_id,
               """
               The question does not say which checkout it came from, or names
               the wrong one.

               The criterion says the working copy *follows from* the agent — an
               agent belongs to exactly one checkout, so deriving it makes
               naming the wrong one impossible, where accepting it from the
               caller does not. This scenario runs two checkouts precisely so
               that "the one the asker was on" and "the one the reader is on"
               are different values: the question was raised on
               #{context.there.working_copy_id} and read from
               #{context.here.working_copy_id}.

               listing:
               #{listing}
               """

        {:ok, context}
      end
    end
  end
end
