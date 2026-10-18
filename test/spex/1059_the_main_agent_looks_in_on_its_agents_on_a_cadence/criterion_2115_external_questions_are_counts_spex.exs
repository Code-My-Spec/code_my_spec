defmodule CodeMySpecSpex.Story1059.Criterion2115Spex do
  @moduledoc "Questions waiting on the user are counted without bodies"
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpecSpex.CompactCadenceHelpers, as: Compact
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Questions waiting on the user are counted without bodies", criterion: 2115 do
    scenario "Questions waiting on the user are counted without bodies" do
      given_ "many agents have questions escalated to the user", context do
        context = Compact.fleet(context, 20)

        for agent <- context.agents do
          frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

          response =
            ToolLibrary.run(
              "ask_user_question",
              %{
                questions: [
                  %{
                    question: "Private detail " <> String.duplicate("long body ", 100),
                    options: [%{label: "Yes"}, %{label: "No"}]
                  }
                ]
              },
              Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
            )

          assert match?({:ok, _}, response), response_text(response)

          Compact.call(context, "escalate_question", %{
            question_id: Fixtures.question_id_from(response_text(response)),
            reason: "The requested retention policy is a product decision for the user."
          })
        end

        {:ok, context}
      end

      when_ "main asks for a check-in", context do
        {:ok, Compact.report(context)}
      end

      then_ "the report omits question bodies and the detail call retrieves them", context do
        assert context.report =~ "user 20; product 0"
        refute context.report =~ "Private detail"
        refute context.report =~ "long body"
        assert context.report =~ "list_notifications({})"
        detail = Compact.call(context, "list_notifications", %{})
        assert detail =~ "Private detail"
        {:ok, context}
      end
    end
  end
end
