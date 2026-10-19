defmodule CodeMySpecSpex.Story1080.Criterion1864Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1864 — A resume or denial notice carries no generic "eligible work
  is available" text.

  Offer 0c828c03 said "resume task 2e2791df" and then "No task has been
  selected or assigned for you" in the same turn.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [user_answers: 3]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A resume notice is only the resume", criterion: 1864 do
    scenario "the question that blocked a task is answered" do
      given_ "a coder blocked its task on a question", context do
        context = coder_holding_a_task(context)

        params = %{
          questions: [%{"question" => "Which way?", "options" => [%{"label" => "Left"}]}]
        }

        reply =
          ToolLibrary.run(
            "ask_question",
            params,
            Map.put(
              agent_frame(context, context.coder).assigns,
              :scope,
              agent_frame(context, context.coder).assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, reply), response_text(reply)
        {:ok, Map.put(context, :question, Fixtures.question_id_from(response_text(reply)))}
      end

      when_ "the user answers it", context do
        :ok = user_answers(context, context.question, "Left")
        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, prompt}, 2_000
        {:ok, Map.put(context, :prompt, prompt)}
      end

      then_ "the turn says to resume the task and nothing generic", context do
        assert context.prompt =~ "resume task #{context.task_id}", context.prompt
        refute context.prompt =~ "Eligible work is available", context.prompt
        refute context.prompt =~ "No task has been selected", context.prompt
        {:ok, context}
      end
    end
  end
end
