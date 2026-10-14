defmodule CodeMySpecSpex.Story1060.Criterion2181Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 2181 — An inspected answer whose citation names nothing the
  answerer actually read is refused as a guess, naming the missing citation,
  and the question stays open.

  Keeps criterion 1224 ("the main agent does not guess at what it merely
  suspects") for the new basis: `inspected` would otherwise be a free pass
  for "I looked at something", with no way to tell a real read from a claimed
  one.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An inspected answer citing nothing the main agent actually read is refused as a guess",
       criterion: 2181 do
    scenario "the citation names a file the main agent never read this session" do
      given_ "a coding agent's question, and a main agent that never read the file it would cite",
             context do
        reply = join_working_copy(context, "/tmp/spex-2181", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        main = Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-2181-main")
        coder = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2181")

        asking = %Frame{assigns: %{current_scope: scope, agent_id: coder.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "which port is dev on",
              questions: [
                %{"question" => "Which port does dev listen on?", "options" => []}
              ]
            },
            asking
          )

        refute asked.isError, inspect(asked)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:main_frame, %Frame{assigns: %{current_scope: scope, agent_id: main.id}})
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "the main agent answers with basis inspected, citing a file it never read", context do
        {:reply, response, _frame} =
          AnswerNotification.execute(
            %{
              notification_id: context.question_id,
              answer: "4004 — the usual dev port",
              basis: "inspected",
              citation: "config/dev.exs"
            },
            context.main_frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it is refused as a guess, naming the missing citation", context do
        assert context.response.isError,
               """
               A citation naming a file the main agent never read this session was
               accepted as if it had been inspected.

               reply:
               #{response_text(context.response)}
               """

        assert response_text(context.response) =~ "config/dev.exs",
               """
               The refusal did not name the citation that could not be matched to
               anything the main agent actually read.

               reply:
               #{response_text(context.response)}
               """

        {:ok, context}
      end

      then_ "and the question stays open, reaching the user rather than being answered wrongly",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListNotifications.execute(%{}, frame)

        assert response_text(listing) =~ ~r/waiting on the user/i,
               """
               The refused guess left the question nowhere rather than escalating
               it.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
