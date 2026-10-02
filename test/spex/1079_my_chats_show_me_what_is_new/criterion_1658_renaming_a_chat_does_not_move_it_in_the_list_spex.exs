defmodule CodeMySpecSpex.Story1079.Criterion1658Spex do
  @moduledoc """
  Story 1079 — My chats show me what is new.
  Criterion 1658 — Renaming a chat does not move it in the list.

  A rename is not activity. The list used to sort by the row's `updated_at`,
  so naming a session sent it to the top as if something had happened in it.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A rename leaves a chat where it was", criterion: 1658 do
    scenario "renaming the older session keeps the newer one first" do
      given_ "a coder spoke, then a QA agent spoke", context do
        coder = Fixtures.running_agent(context.scope, role: "coding")
        qa = Fixtures.running_agent(context.scope, role: "qa")

        :ok = Fixtures.agent_said(context.scope, coder, "Starting the refund fix")
        :ok = Fixtures.agent_said(context.scope, qa, "Checking the login page")

        {:ok,
         Map.merge(context, %{
           coder_chat: Fixtures.agent_conversation(context.scope, coder).id,
           qa_chat: Fixtures.agent_conversation(context.scope, qa).id
         })}
      end

      when_ "I rename the coder's session", context do
        {:ok, live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversations")

        assert session_order(html) == [context.qa_chat, context.coder_chat],
               "the QA agent spoke last, so its session should lead before the rename"

        live
        |> element(
          "[data-test='rename-agent-conversation-start'][phx-value-id='#{context.coder_chat}']"
        )
        |> render_click()

        html =
          live
          |> form("[data-test='rename-agent-conversation']", %{name: "Refunds"})
          |> render_submit()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the renamed session keeps its place below the QA one", context do
        assert context.html =~ "Refunds", "the rename did not take"

        assert session_order(context.html) == [context.qa_chat, context.coder_chat],
               "renaming the coder's session moved it above a session with newer activity"

        {:ok, context}
      end
    end
  end

  defp session_order(html) do
    ~r/data-conversation-id="([^"]+)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end
end
