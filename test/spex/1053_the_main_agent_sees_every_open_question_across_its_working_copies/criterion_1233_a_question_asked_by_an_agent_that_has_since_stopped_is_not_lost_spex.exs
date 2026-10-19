defmodule CodeMySpecSpex.Story1053.Criterion3263Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question and message across its
  working copies.
  Criterion 3263 — A question asked by an agent that has since stopped is not
  lost.

  Rule: a question outlives the process that asked it.

  The one failure here that cannot be noticed from the outside. An unanswered
  question that disappears leaves nothing behind — no entry, no error, no agent
  complaining — and the work it was blocking simply never resumes. Every other
  criterion on this story fails visibly by comparison: a short list is at least
  a list.

  It is also the likeliest thing to get wrong, because stopping an agent is a
  real cleanup path and a question is exactly the sort of thing a cleanup path
  takes with it. An agent is restarted whenever its harness reconnects, its
  machine reboots, or somebody promotes — so "the agent that asked is gone" is
  ordinary rather than exceptional, and a question that cannot survive it is a
  question that rarely survives at all.

  The process ends and the record still says the agent should run -- what a
  restart does. An agent somebody turned off is a different thing: nobody means
  it to answer, so the listing leaves its questions out, as the notifications
  page does (issue 83d3ecd2). A scenario that deleted the row would be testing
  its own delete.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A question survives the agent that raised it", criterion: 1233 do
    scenario "the asking agent's process ends before anyone answers" do
      given_ "an agent with an open question", context do
        reply = join_working_copy(context, "/tmp/spex-3263", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3263"
          )

        frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        response =
          ToolLibrary.run(
            "ask_user_question",
            %{
              title: "a question raised before stopping",
              questions: [
                %{
                  "question" => "Should the migration run before or after the swap?",
                  "options" => [%{"label" => "Before"}, %{"label" => "After"}]
                }
              ]
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response), inspect(response)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "that agent's process ends, as it does on every restart", context do
        {:ok, stopped} =
          CodeMySpec.Agents.AgentsRepository.update_agent(context.scope, context.agent, %{
            status: :stopped
          })

        assert stopped.status == :stopped
        assert is_nil(stopped.off_at) and is_nil(stopped.retired_at)

        {:ok, context}
      end

      then_ "the question is still waiting", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response), inspect(response)

        assert response_text(response) =~
                 "Should the migration run before or after the swap?",
               """
               The question disappeared with the agent that asked it.

               Nothing else reports this. There is no entry, no error, and no
               agent left to complain — the work the question was blocking
               simply never resumes, and the only evidence is a project that
               quietly stopped moving.

               An agent is restarted whenever its harness reconnects, its
               machine reboots, or somebody promotes. So this is the ordinary
               case rather than the exceptional one, and a question that cannot
               survive it is a question that rarely survives.

               listing:
               #{response_text(response)}
               """

        {:ok, context}
      end
    end
  end
end
