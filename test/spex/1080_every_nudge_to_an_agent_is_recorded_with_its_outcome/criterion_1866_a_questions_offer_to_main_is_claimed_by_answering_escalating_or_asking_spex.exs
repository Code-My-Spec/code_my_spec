defmodule CodeMySpecSpex.Story1080.Criterion1866Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1866 — A questions offer to main is claimed when main answers,
  escalates or asks the user about a waiting question after the offer.

  Nine of the thirteen "ignored" questions offers measured on 2026-10-02 were
  main escalating a question it could not answer — the right move, scored as
  ignoring the offer because only `answer_notification` counted.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [ask: 2, main_escalates: 3]

  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport()
    :ok
  end

  spex "Main escalating a waiting question claims the offer", criterion: 1866 do
    scenario "a teammate's question main cannot answer" do
      given_ "a continuous main with no graph work of its own", context do
        context = FullSatisfactionFixtures.apply(context)

        {:ok, _} =
          WorkingCopies.designate_main(context.scope, context.scope.active_working_copy_id)

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        {:ok, Map.put(context, :main_id, main.id)}
      end

      given_ "a teammate asks a question, and main is offered it", context do
        question = ask(context, "Should bookings expire after a day?")
        id = context.main_id
        assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        {:ok, Map.put(context, :question, question)}
      end

      when_ "main escalates it to the user and ends its turn", context do
        :ok =
          Fixtures.agent_tool_call(
            context.scope,
            %{id: context.main_id},
            "e1",
            "escalate_question",
            %{
              "question_id" => context.question
            }
          )

        main_escalates(context, context.question, "A product decision, not mine to make.")
        :ok = Fixtures.end_turn(context.scope, context.main_id)
        {:ok, context}
      end

      then_ "main's questions offer is claimed", context do
        assert [%{subject: "questions", status: "claimed"} | _] =
                 context
                 |> offers(context.main_id, %{kind: "work"})
                 |> Enum.filter(&String.starts_with?(&1.subject, "questions")),
               listing(context)

        {:ok, context}
      end
    end
  end
end
