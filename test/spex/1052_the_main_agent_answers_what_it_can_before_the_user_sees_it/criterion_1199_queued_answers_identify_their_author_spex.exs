defmodule CodeMySpecSpex.Story1052.Criterion3219Spex do
  @moduledoc """
  Answer attribution belongs to the saved question, not a chat delivery.
  Main answers from a known checkout record, the user answers a separate
  decision, and the originating agent reads both twice without taking a turn.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Saved answers identify their actual author without message delivery", criterion: 1199 do
    scenario "An idle agent reads the user and main answers repeatedly" do
      given_ "an agent has two pending questions and an idle continuous-off engine", context do
        context = given_a_staffed_checkout(context, "spex_3219")
        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        main = Fixtures.running_agent(context.scope, role: "main", continuous: false)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        main_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}}
        recorded_answer = "Working copy #{context.scope.active_working_copy_id}"

        [technical, product] =
          Enum.map(
            [
              {"Which working copy owns this implementation?", recorded_answer},
              {"Should exports include archived receipts?", "Include archived receipts"}
            ],
            fn {question, choice} ->
              asked =
                ToolLibrary.run(
                  "ask_question",
                  %{
                    questions: [
                      %{
                        question: question,
                        options: [%{label: choice}, %{label: "Something else"}]
                      }
                    ]
                  },
                  Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
                )

              assert match?({:ok, _}, asked), response_text(asked)
              Fixtures.question_id_from(response_text(asked))
            end
          )

        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)
        assert {:ok, %{busy?: false}} = Machine.status(agent.id)

        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: agent.id},
            Map.put(main_frame.assigns, :scope, main_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           frame: frame,
           main_frame: main_frame,
           technical_id: technical,
           product_id: product,
           recorded_answer: recorded_answer,
           conversation_before: response_text(conversation)
         })}
      end

      when_ "main answers the technical question and the user answers the product decision",
            context do
        answered =
          ToolLibrary.run(
            "answer_notification",
            %{
              notification_id: context.technical_id,
              answer: context.recorded_answer,
              basis: "record"
            },
            Map.put(
              context.main_frame.assigns,
              :scope,
              context.main_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, answered), response_text(answered)
        {:ok, view, _} = live(context.conn, "/app/questions/#{context.product_id}")

        view
        |> form("main [data-test='question-form']", %{"q_0" => "Include archived receipts"})
        |> render_submit()

        assert render(view) =~ "Answer sent."
        {:ok, context}
      end

      then_ "repeated question reads preserve the answer text and the actual author", context do
        for _ <- 1..2 do
          technical =
            ToolLibrary.run(
              "check_answer",
              %{question_id: context.technical_id},
              Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
            )

          assert match?({:ok, _}, technical), response_text(technical)
          assert response_text(technical) =~ context.recorded_answer
          assert response_text(technical) =~ ~r/main agent replied/i
          refute response_text(technical) =~ ~r/user replied/i

          product =
            ToolLibrary.run(
              "check_answer",
              %{question_id: context.product_id},
              Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
            )

          assert match?({:ok, _}, product), response_text(product)
          assert response_text(product) =~ "Include archived receipts"
          assert response_text(product) =~ ~r/user replied/i
          refute response_text(product) =~ ~r/main agent replied/i
        end

        {:ok, context}
      end

      then_ "no conversation delivery or model turn is needed for that attribution", context do
        assert {:ok, %{busy?: false}} = Machine.status(context.agent_id)
        assert HeldProvider.seen() == []

        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: context.agent_id},
            Map.put(
              context.main_frame.assigns,
              :scope,
              context.main_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, conversation), response_text(conversation)
        assert response_text(conversation) == context.conversation_before
        {:ok, context}
      end
    end
  end
end
