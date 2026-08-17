defmodule CodeMySpecSpex.Story960.Criterion8330Spex do
  @moduledoc """
  Story 960 — Shared inbox for end-user conversations.
  Criterion 8330 — Two projects one inbox.

  Rule: The inbox lists every conversation in the account, whichever project it came from.

  An operator has one queue of people waiting, not one per project. Splitting
  it by project means someone waits longer because their message landed on the
  side Sam was not looking at.

  Surface: `CodeMySpecWeb.InboxLive` at `/app/projects/:project_id/inbox`, with
  the visitor's half driven over `CodeMySpecWeb.ConversationChannel` — the two
  ends of one conversation, which is the only way to prove a reply arrives.
  """

  use CodeMySpecSpex.Case

  # The spex Case imports Plug.Conn and Phoenix.LiveViewTest, which export their
  # own push/3 and assert_reply/3. The channel's are qualified at the call site.
  import Phoenix.ChannelTest, except: [push: 3, assert_reply: 3]

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  defp join_widget(project_id, end_user_id, email) do
    CodeMySpecWeb.WidgetSocket
    |> socket("widget:#{end_user_id}", %{
      project_id: project_id,
      end_user_id: end_user_id,
      end_user_email: email
    })
    |> subscribe_and_join(CodeMySpecWeb.ConversationChannel, "conversation:#{end_user_id}", %{})
  end

  defp inbox_path(project), do: "/app/projects/#{project.id}/inbox"

  spex "One queue across the account" do
    scenario "Two projects, one inbox" do
      given_ "visitors have written in from two of Sam's projects", context do
        other = Fixtures.project_fixture(context.scope)

        {:ok, _, first} = join_widget(context.project.id, "eu-p1", "p1@example.com")

        r1 =
          Phoenix.ChannelTest.push(first, "send_message", %{"body" => "from the first project"})

        Phoenix.ChannelTest.assert_reply(r1, :ok, _, 1000)

        {:ok, _, second} = join_widget(other.id, "eu-p2", "p2@example.com")

        r2 =
          Phoenix.ChannelTest.push(second, "send_message", %{"body" => "from the second project"})

        Phoenix.ChannelTest.assert_reply(r2, :ok, _, 1000)

        {:ok, Map.put(context, :other_project, other)}
      end

      when_ "he opens the inbox", context do
        {:ok, _inbox, html} = live(context.conn, inbox_path(context.project))

        {:ok, Map.put(context, :html, html)}
      end

      then_ "both conversations are listed", context do
        assert context.html =~ "p1@example.com",
               "expected the first project's visitor"

        assert context.html =~ "p2@example.com",
               "expected the second project's visitor in the same inbox"

        {:ok, context}
      end
    end
  end
end
