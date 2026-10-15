defmodule CodeMySpecSpex.Story1079.Criterion1663Spex do
  @moduledoc """
  Story 1079 — My chats show me what is new.
  Criterion 1663 — The inbox's unread count counts chats unread for me.

  The count in the header is how many chats I have not seen. It follows my own
  reading, not the account's or a teammate's.
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

  spex "The unread count is mine", criterion: 1663 do
    scenario "I read one of two chats, and my teammate reads the other" do
      given_ "Ann and Bob wrote in, and a teammate shares my account", context do
        _ann = join_and_send(context, "ann-1663", "ann1663@example.com", "Ann here")
        _bob = join_and_send(context, "bob-1663", "bob1663@example.com", "Bob here")

        teammate = Fixtures.user_fixture()
        _member = Fixtures.member_fixture(teammate, context.account, :member)
        teammate_scope = Fixtures.user_scope_fixture(teammate, context.account)
        Fixtures.select_active_account(teammate_scope, context.account.id)

        {:ok, Map.put(context, :teammate_conn, log_in_user(build_conn(), teammate))}
      end

      when_ "I open Ann's chat and my teammate opens Bob's", context do
        {:ok, _live, html} = inbox(context.conn, context)
        assert count(html) == "2 unread", "two unseen chats should start at 2 unread"

        open(context.conn, context, row_id(html, "ann1663@example.com"))
        open(context.teammate_conn, context, row_id(html, "bob1663@example.com"))

        {:ok, _live, html} = inbox(context.conn, context)
        {:ok, Map.put(context, :html, html)}
      end

      then_ "my count is 1, for Bob's chat that I have not seen", context do
        assert count(context.html) == "1 unread",
               "I have seen Ann's chat and not Bob's, so my count should be 1 " <>
                 "(got #{inspect(count(context.html))})"

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

  defp inbox(conn, context), do: live(conn, ~p"/app/projects/#{context.project.id}/inbox")

  defp open(conn, context, id) do
    {:ok, _show, _html} = live(conn, ~p"/app/projects/#{context.project.id}/inbox/#{id}")
  end

  defp count(html) do
    [_, text] = Regex.run(~r/data-test="unread-count"[^>]*>\s*([^<]+?)\s*</, html)
    text
  end

  defp row(html, email),
    do: html |> String.split("<tr") |> Enum.find(&String.contains?(&1, email))

  defp row_id(html, email) do
    [_, id] = Regex.run(~r/phx-value-id="([^"]+)"/, row(html, email))
    id
  end
end
