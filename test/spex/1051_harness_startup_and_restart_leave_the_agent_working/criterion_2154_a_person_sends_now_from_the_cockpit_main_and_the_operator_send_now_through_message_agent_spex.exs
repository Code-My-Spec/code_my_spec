defmodule CodeMySpecSpex.Story1051.Criterion2154Spex do
  @moduledoc """
  Story 1051 — A person sends now from the cockpit; main and the operator send now through message_agent.
  Rule: A message sent now reaches a busy agent at its next tool boundary, inside the running turn; nothing is cancelled.
  """
  use CodeMySpecSpex.Case
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.MailboxHelpers, as: H
  import Phoenix.LiveViewTest
  alias CodeMySpec.Conversations
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "a person sends a waiting message now from the cockpit", criterion: 2154 do
    scenario "John sees his message waiting and wants it in now" do
      given_ "a coder about to call a tool, and John's message waiting in the cockpit", ctx do
        ctx = ctx |> H.start() |> H.mid_turn_before_a_tool_call()

        {:ok, conversation} =
          Conversations.find_or_create_agent_conversation(
            ctx.scope.active_account_id,
            ctx.scope.active_project_id,
            ctx.agent.id
          )

        path =
          "/app/projects/#{ctx.scope.active_project_id}/agent-conversation?conversation=#{conversation.id}"

        {:ok, view, _html} = live(ctx.conn, path)

        view
        |> form("[data-test='agent-message-form']", %{message: "FROM-THE-COCKPIT"})
        |> render_submit()

        {:ok, Map.put(ctx, :view, view)}
      end

      when_ "he presses Send now, and the call runs", ctx do
        ctx.view |> element("[data-test='agent-send-now']") |> render_click()
        {:ok, H.boundary(ctx)}
      end

      then_ "the model's next request carries his message", ctx do
        assert H.after_the_tool_call() =~ "FROM-THE-COCKPIT"
        {:ok, ctx}
      end
    end
  end

  spex "main sends now through message_agent", criterion: 2154 do
    scenario "main redirects a coder" do
      given_ "a coder about to call a tool", ctx do
        {:ok, ctx |> H.start() |> H.mid_turn_before_a_tool_call()}
      end

      when_ "main calls message_agent with send_now", ctx do
        H.message(ctx, "FROM-MAIN", send_now: true)
        {:ok, H.boundary(ctx)}
      end

      then_ "the model's next request carries it", ctx do
        assert H.after_the_tool_call() =~ "FROM-MAIN"
        {:ok, ctx}
      end
    end
  end
end
