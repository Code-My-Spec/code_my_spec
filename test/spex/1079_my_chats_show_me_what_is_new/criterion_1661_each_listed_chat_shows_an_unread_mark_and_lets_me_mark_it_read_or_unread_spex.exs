defmodule CodeMySpecSpex.Story1079.Criterion1661Spex do
  @moduledoc """
  Story 1079 — My chats show me what is new.
  Criterion 1661 — Each listed chat shows an unread mark and lets me mark it
  read or unread.

  Like an email client: the mark is on the row, and so is the switch, so I can
  clear a chat without opening it or flag one to come back to.
  """

  use CodeMySpecSpex.Case

  import Phoenix.ChannelTest
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  @email "ann1661@example.com"

  spex "The unread mark and its switch are on the row", criterion: 1661 do
    scenario "a support chat in the inbox" do
      given_ "Ann wrote in and I have not looked", context do
        _ann = join_and_send(context, "ann-1661", @email, "Can you help?")
        {:ok, context}
      end

      when_ "I mark her chat read from the list, then unread again", context do
        {:ok, live, html} = inbox(context)
        toggle = "[data-test='toggle-read'][phx-value-id='#{row_id(html, @email)}']"

        before = html
        read = live |> element(toggle) |> render_click()
        unread = live |> element(toggle) |> render_click()

        {:ok, Map.merge(context, %{before: before, read: read, unread: unread})}
      end

      then_ "the row shows the mark, loses it, and gets it back", context do
        assert row(context.before, @email) =~ ~s(data-test="unread-dot"),
               "an unseen chat has no unread mark on its row"

        refute row(context.read, @email) =~ ~s(data-test="unread-dot"),
               "Mark read on the row left the unread mark in place"

        assert row(context.unread, @email) =~ ~s(data-test="unread-dot"),
               "Mark unread on the row did not bring the mark back"

        {:ok, context}
      end
    end

    scenario "an agent session in the sessions list" do
      given_ "a coder has said something I have not seen", context do
        coder = Fixtures.running_agent(context.scope, role: "coding")
        :ok = Fixtures.agent_said(context.scope, coder, "Starting the refund fix")

        {:ok, Map.put(context, :chat, Fixtures.agent_conversation(context.scope, coder).id)}
      end

      when_ "I mark its session read from the list, then unread again", context do
        {:ok, live, before} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversations")

        toggle = "[data-conversation-id='#{context.chat}'] [data-test='toggle-read']"
        read = live |> element(toggle) |> render_click()
        unread = live |> element(toggle) |> render_click()

        {:ok, Map.merge(context, %{before: before, read: read, unread: unread})}
      end

      then_ "the row shows the mark, loses it, and gets it back", context do
        mark = ~r/data-conversation-id="#{context.chat}"\s+data-unread="true"/

        assert context.before =~ mark, "an unseen session is not marked unread"
        refute context.read =~ mark, "Mark read on the row left the session unread"
        assert context.unread =~ mark, "Mark unread on the row did not mark the session unread"

        {:ok, context}
      end
    end
  end

  defp join_and_send(context, end_user_id, email, body) do
    {:ok, _reply, channel} =
      CodeMySpecWeb.WidgetSocket
      |> socket("widget:#{end_user_id}", %{
        project_id: context.project.id,
        end_user_id: end_user_id,
        end_user_email: email
      })
      |> subscribe_and_join(CodeMySpecWeb.ConversationChannel, "conversation:#{end_user_id}", %{})

    Phoenix.ChannelTest.push(channel, "send_message", %{"body" => body})
    wait_for_channel(channel)
    channel
  end

  defp inbox(context), do: live(context.conn, ~p"/app/projects/#{context.project.id}/inbox")

  defp row(html, email),
    do: html |> String.split("<tr") |> Enum.find(&String.contains?(&1, email))

  defp row_id(html, email) do
    [_, id] = Regex.run(~r/phx-value-id="([^"]+)"/, row(html, email))
    id
  end
end
