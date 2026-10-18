defmodule CodeMySpecSpex.Story1080.Criterion1871Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1871 — Offered a teammate's question it cannot answer, main
  escalates it with escalate_question and does not ask the user the same
  question itself.

  `EscalateQuestion`'s own moduledoc: use it "when the decision is theirs
  — what to build, what it is worth, which way the product goes." The
  question's holder moves; it is not closed, reassigned or copied.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.EscalateQuestion
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "Main escalates a teammate's question instead of answering or re-asking it", criterion: 1871 do
    scenario "a coder asks something only the user can decide" do
      given_ "a coder asked a question, and main holding the resulting offer", context do
        context = coder_holding_a_task(context)

        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              task_id: context.task_id,
              questions: [
                %{
                  "question" => "What should the refund window be?",
                  "options" => [%{"label" => "30 days"}, %{"label" => "60 days"}]
                }
              ]
            },
            agent_frame(context, context.coder)
          )

        refute asked.isError, response_text(asked)
        question_id = Fixtures.question_id_from(response_text(asked))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      when_ "main escalates it to the user, unable to decide it itself", context do
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.coder}}

        {:reply, escalated, _} =
          EscalateQuestion.execute(
            %{
              question_id: context.question_id,
              reason: "This is a product decision, not an engineering one."
            },
            frame
          )

        {:ok, Map.put(context, :escalated, escalated)}
      end

      then_ "the question moves to the user rather than being answered or reassigned", context do
        refute context.escalated.isError, response_text(context.escalated)
        assert response_text(context.escalated) =~ "Sent to the user", response_text(context.escalated)
        {:ok, context}
      end

      then_ "main does not ask the user the same question again itself", context do
        {:reply, open, _} =
          ListNotifications.execute(%{}, %Frame{assigns: %{current_scope: context.scope}})

        refute open.isError, response_text(open)
        matches = Regex.scan(~r/refund window/, response_text(open))
        assert length(matches) == 1, "the question was duplicated:\n" <> response_text(open)
        {:ok, context}
      end
    end
  end
end
