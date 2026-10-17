defmodule CodeMySpecSpex.Story1079.Criterion1660Spex do
  @moduledoc """
  Story 1079 — My chats show me what is new.
  Criterion 1660 — Opening a chat marks it read, and a message arriving while I
  view it keeps it read.

  A message I watched arrive is one I have seen. Coming back to the list should
  not tell me otherwise.
  """

  use CodeMySpecSpex.Case

  import Phoenix.ChannelTest
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  @email "ann1660@example.com"

  spex "Reading a chat is opening it", criterion: 1660 do
    scenario "opening an unread chat reads it" do
      given_ "Ann wrote in and I have not looked", context do
        _ann = join_and_send(context, "ann-1660", @email, "Can you help?")
        {:ok, context}
      end

      when_ "I open her chat from the inbox", context do
        {:ok, live, html} = inbox(context)
        assert unread?(html, @email), "Ann's chat should start out unread"

        {:ok, _show, _html} =
          live
          |> element("[data-test='conversation'][phx-value-id='#{row_id(html, @email)}']")
          |> render_click()
          |> follow_redirect(context.conn)

        {:ok, context}
      end

      then_ "her chat shows read when I go back", context do
        {:ok, _live, html} = inbox(context)
        refute unread?(html, @email), "I opened Ann's chat and the inbox still shows it unread"

        {:ok, context}
      end
    end

    scenario "a message arriving while the chat is on screen keeps it read" do
      given_ "I have Ann's chat open", context do
        ann = join_and_send(context, "ann-1660", @email, "Can you help?")
        {:ok, _live, html} = inbox(context)

        {:ok, show, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/inbox/#{row_id(html, @email)}"
          )

        {:ok, Map.merge(context, %{ann: ann, show: show})}
      end

      when_ "Ann writes while I am looking at it", context do
        Phoenix.ChannelTest.push(context.ann, "send_message", %{"body" => "Still there?"})
        wait_for_channel(context.ann)

        assert render(context.show) =~ "Still there?",
               "Ann's new message never reached the open chat"

        {:ok, context}
      end

      then_ "her chat is still read when I go back", context do
        {:ok, _live, html} = inbox(context)

        refute unread?(html, @email),
               "Ann's message arrived on my screen and the inbox calls it unread"

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

  defp unread?(html, email), do: row(html, email) =~ ~s(data-unread="true")
end
