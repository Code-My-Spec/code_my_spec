defmodule CodeMySpecSpex.Story1079.Criterion1659Spex do
  @moduledoc """
  Story 1079 — My chats show me what is new.
  Criterion 1659 — A chat is unread for me when it has a message newer than my
  last read, or I marked it unread.
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

  @email "ann1659@example.com"

  spex "Unread means something new since I last read it, or I said so", criterion: 1659 do
    scenario "a message after I read the chat makes it unread again" do
      given_ "Ann wrote in, and I read her chat and went back to the list", context do
        ann = join_and_send(context, "ann-1659", @email, "First question")
        {:ok, _live, html} = inbox(context)

        {:ok, show, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/inbox/#{row_id(html, @email)}"
          )

        # Leaving the chat: a chat still on screen stays read (criterion 1660).
        {:ok, _list, _html} =
          live_redirect(show, to: ~p"/app/projects/#{context.project.id}/inbox")

        {:ok, Map.put(context, :ann, ann)}
      end

      when_ "Ann writes again after I left", context do
        {:ok, _live, html} = inbox(context)
        refute unread?(html, @email), "I just read Ann's chat, so it should start out read"

        Phoenix.ChannelTest.push(context.ann, "send_message", %{"body" => "Second question"})
        wait_for_channel(context.ann)

        {:ok, _live, html} = inbox(context)
        {:ok, Map.put(context, :html, html)}
      end

      then_ "her chat is unread", context do
        assert unread?(context.html, @email),
               "Ann's chat has a message newer than my last read and is not marked unread"

        {:ok, context}
      end
    end

    scenario "marking a read chat unread makes it unread with nothing new" do
      given_ "Ann wrote in and I read her chat", context do
        _ann = join_and_send(context, "ann-1659", @email, "First question")
        {:ok, _live, html} = inbox(context)

        {:ok, _show, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/inbox/#{row_id(html, @email)}"
          )

        {:ok, context}
      end

      when_ "I mark it unread", context do
        {:ok, live, html} = inbox(context)
        refute unread?(html, @email), "I just read Ann's chat, so it should start out read"

        html =
          live
          |> element("[data-test='toggle-read'][phx-value-id='#{row_id(html, @email)}']")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "her chat is unread, and stays so when I come back", context do
        assert unread?(context.html, @email), "I marked Ann's chat unread and it shows read"

        {:ok, _live, html} = inbox(context)
        assert unread?(html, @email), "the unread mark did not survive reloading the inbox"

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
