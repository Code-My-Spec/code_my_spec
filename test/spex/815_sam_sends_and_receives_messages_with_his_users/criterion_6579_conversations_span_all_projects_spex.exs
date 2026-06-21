defmodule CodeMySpecSpex.Story815.Criterion6579Spex do
  @moduledoc """
  Story 815 — Sam sends and receives messages with his users.
  Criterion 6579 — Conversations span all projects.

  Rule: The account sees conversations from all of its projects in one inbox.

  Surfaces (forward-looking — red until built):
    * `CodeMySpecWeb.WidgetSocket` + `CodeMySpecWeb.ConversationChannel` — each
      conversation is scoped to a project via the socket's `project_id` assign.
    * `CodeMySpecWeb.InboxLive` at "/app/inbox" — a single, account-wide inbox
      that lists conversations across every project the account owns.
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @user_x "end-user-6579-x"
  @user_x_email "xavier@example.com"
  @user_y "end-user-6579-y"
  @user_y_email "yolanda@example.com"

  spex "One inbox shows conversations from all of the account's projects" do
    scenario "Conversations span all projects" do
      given_ "the account has two projects, each with a conversation", context do
        {:ok, _rx, chan_x} =
          CodeMySpecWeb.WidgetSocket
          |> socket("widget:#{@user_x}", %{
            project_id: context.project.id,
            end_user_id: @user_x,
            end_user_email: @user_x_email
          })
          |> subscribe_and_join(
            CodeMySpecWeb.ConversationChannel,
            "conversation:#{@user_x}",
            %{}
          )

        Phoenix.ChannelTest.push(chan_x, "send_message", %{"body" => "From project one"})
        wait_for_channel(chan_x)

        dir2 = Path.join(System.tmp_dir!(), "spex-#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir2)
        on_exit(fn -> File.rm_rf(dir2) end)

        project2 =
          Fixtures.project_fixture(context.scope,
            account_id: context.account.id,
            local_path: dir2
          )

        {:ok, _ry, chan_y} =
          CodeMySpecWeb.WidgetSocket
          |> socket("widget:#{@user_y}", %{
            project_id: project2.id,
            end_user_id: @user_y,
            end_user_email: @user_y_email
          })
          |> subscribe_and_join(
            CodeMySpecWeb.ConversationChannel,
            "conversation:#{@user_y}",
            %{}
          )

        Phoenix.ChannelTest.push(chan_y, "send_message", %{"body" => "From project two"})
        wait_for_channel(chan_y)

        {:ok, Map.put(context, :project2, project2)}
      end

      when_ "the operator opens the inbox", context do
        {:ok, _view, html} = live(context.conn, "/app/inbox")
        {:ok, Map.put(context, :html, html)}
      end

      then_ "conversations from both projects are shown together", context do
        html = context.html

        assert html =~ "From project one", "expected the first project's conversation"
        assert html =~ "From project two", "expected the second project's conversation"
        assert html =~ @user_x_email, "expected the first project's user"
        assert html =~ @user_y_email, "expected the second project's user"

        {:ok, context}
      end
    end
  end
end
