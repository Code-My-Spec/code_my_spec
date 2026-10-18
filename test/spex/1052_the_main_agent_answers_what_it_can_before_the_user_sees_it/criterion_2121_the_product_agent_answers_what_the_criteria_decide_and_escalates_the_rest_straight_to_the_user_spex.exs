defmodule CodeMySpecSpex.Story1052.Criterion2121Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 2121 — The product agent answers what the criteria decide and
  escalates the rest straight to the user.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.EscalateQuestion
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The product agent escalates what its criteria do not decide straight to the user",
    criterion: 2121 do
    scenario "a coder's question about a criterion is not decided by the criteria" do
      given_ "a coder's criteria question is waiting on product", context do
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        product = Fixtures.running_agent(context.scope, role: "product", continuous: true)

        params = %{
          about: "criteria",
          questions: [
            %{"question" => "Does criterion 944 cover international refunds?", "options" => []}
          ]
        }

        coder_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}

        reply =
          ToolLibrary.run(
            "ask_user_question",
            params,
            Map.put(coder_frame.assigns, :scope, coder_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, reply), response_text(reply)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(reply))

        {:ok,
         Map.merge(context, %{
           question_id: question_id,
           product_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: product.id}}
         })}
      end

      when_ "product escalates it to the user, since the criteria leave it open", context do
        {:reply, reply, _frame} =
          EscalateQuestion.execute(
            %{
              question_id: context.question_id,
              reason: "The criteria never mention international refunds."
            },
            context.product_frame
          )

        refute reply.isError, response_text(reply)
        {:ok, Map.put(context, :escalate_reply, reply)}
      end

      then_ "it reaches the user", context do
        {:ok, view, _html} = live(context.conn, "/app/notifications")

        assert has_element?(view, "[data-test='notification'][data-id='#{context.question_id}']"),
               """
               Product's escalation never reached the user's own inbox.

               #{render(view)}
               """

        {:ok, context}
      end

      then_ "and it still shows in product's own listing, now waiting on the user", context do
        {:reply, listing, _frame} = ListNotifications.execute(%{}, context.product_frame)

        assert response_text(listing) =~ "Waiting on the user" and
                 response_text(listing) =~ context.question_id,
               """
               An escalated question should stay in the escalating agent's own \
               listing, marked as waiting on the user rather than disappearing.

               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end
