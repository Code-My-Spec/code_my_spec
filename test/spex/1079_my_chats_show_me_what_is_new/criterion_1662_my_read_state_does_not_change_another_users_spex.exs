defmodule CodeMySpecSpex.Story1079.Criterion1662Spex do
  @moduledoc """
  Story 1079 — My chats show me what is new.
  Criterion 1662 — My read state does not change another user's.

  Read is about who has seen it. My teammate opening a chat does not mean I
  have, and the reverse.
  """

  use CodeMySpecSpex.Case

  import Phoenix.ChannelTest
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  @email "ann1662@example.com"

  spex "Read state is mine alone", criterion: 1662 do
    scenario "I read a chat my teammate has not" do
      given_ "Ann wrote in, and a teammate shares my account", context do
        _ann = join_and_send(context, "ann-1662", @email, "Can you help?")

        teammate = Fixtures.user_fixture()
        _member = Fixtures.member_fixture(teammate, context.account, :member)
        teammate_scope = Fixtures.user_scope_fixture(teammate, context.account)
        Fixtures.select_active_account(teammate_scope, context.account.id)

        {:ok, Map.put(context, :teammate_conn, log_in_user(build_conn(), teammate))}
      end

      when_ "I open Ann's chat", context do
        {:ok, _live, html} = inbox(context.conn, context)

        {:ok, _show, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/inbox/#{row_id(html, @email)}"
          )

        {:ok, context}
      end

      then_ "it is read for me and still unread for my teammate", context do
        {:ok, _live, mine} = inbox(context.conn, context)
        {:ok, _live, theirs} = inbox(context.teammate_conn, context)

        refute unread?(mine, @email), "I opened Ann's chat and it shows unread to me"

        assert unread?(theirs, @email),
               "my teammate never opened Ann's chat, but my reading it marked it read for them"

        {:ok, context}
      end
    end

    scenario "my teammate marks a chat unread that I have read" do
      given_ "Ann wrote in, I read her chat, and a teammate shares my account", context do
        _ann = join_and_send(context, "ann-1662", @email, "Can you help?")

        teammate = Fixtures.user_fixture()
        _member = Fixtures.member_fixture(teammate, context.account, :member)
        teammate_scope = Fixtures.user_scope_fixture(teammate, context.account)
        Fixtures.select_active_account(teammate_scope, context.account.id)

        {:ok, _live, html} = inbox(context.conn, context)

        {:ok, _show, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/inbox/#{row_id(html, @email)}"
          )

        {:ok, Map.put(context, :teammate_conn, log_in_user(build_conn(), teammate))}
      end

      when_ "my teammate marks it read and then unread", context do
        {:ok, live, html} = inbox(context.teammate_conn, context)
        toggle = "[data-test='toggle-read'][phx-value-id='#{row_id(html, @email)}']"
        _read = live |> element(toggle) |> render_click()
        _unread = live |> element(toggle) |> render_click()

        {:ok, context}
      end

      then_ "it is still read for me", context do
        {:ok, _live, mine} = inbox(context.conn, context)

        refute unread?(mine, @email),
               "my teammate marked Ann's chat unread and it became unread for me too"

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

  defp row(html, email),
    do: html |> String.split("<tr") |> Enum.find(&String.contains?(&1, email))

  defp row_id(html, email) do
    [_, id] = Regex.run(~r/phx-value-id="([^"]+)"/, row(html, email))
    id
  end

  defp unread?(html, email), do: row(html, email) =~ ~s(data-unread="true")
end
