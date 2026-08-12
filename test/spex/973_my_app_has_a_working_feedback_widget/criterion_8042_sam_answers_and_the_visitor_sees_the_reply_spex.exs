defmodule CodeMySpecSpex.Story973.Criterion8042Spex do
  @moduledoc """
  Story 973 — My app has a working feedback widget
  Criterion 8042 — Sam answers and the visitor sees the reply.

  The channel is two-way. Sam replies from CodeMySpec and the visitor sees
  it in the widget without reloading. One-way feedback is a suggestion box;
  the reply path is what makes it a conversation.

  Surface: the widget socket for the visitor, LiveView for Sam's reply.
  """

  use CodeMySpecSpex.Case
  # connect/3 and push/3 collide with Phoenix.ConnTest and Plug.Conn, which
  # CodeMySpecSpex.Case also imports. Require + qualify those two; import the
  # rest, since assert_reply/assert_push are macros and cannot be qualified
  # without the require anyway.
  import Phoenix.ChannelTest, except: [connect: 3, push: 3]
  require Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Sam answers and the visitor sees the reply" do
    scenario "a reply from CodeMySpec is pushed to the open widget" do
      given_ "a visitor's message has arrived", context do
        # The app holds the credential and mints the browser's socket token;
        # the visitor names no project and has no account.
        app_token = app_access_token(context.project)

        body =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer " <> app_token)
          |> get("/api/widget/socket_token")
          |> Phoenix.ConnTest.json_response(200)

        visitor = "visitor-#{System.unique_integer([:positive])}"

        {:ok, socket} =
          Phoenix.ChannelTest.connect(
            CodeMySpecWeb.WidgetSocket,
            %{
              "socket_token" => body["socket_token"],
              "user_id" => visitor,
              "user_email" => "#{visitor}@example.com"
            },
            connect_info: %{}
          )

        {:ok, _reply, channel} = subscribe_and_join(socket, "conversation:#{visitor}", %{})

        ref = Phoenix.ChannelTest.push(channel, "send_message", %{"body" => "is anyone there"})
        assert_reply(ref, :ok, %{}, 1000)

        {:ok, context |> Map.put(:channel, channel) |> Map.put(:visitor, visitor)}
      end

      when_ "Sam replies from CodeMySpec", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/inbox")

        # The reply form lives on the conversation, not the list, so Sam opens
        # the one the visitor started. `open_conversation` is a `push_navigate`,
        # which ends this LiveView process and starts another — clicking and
        # then using the old view is how the previous attempt got "no process".
        {:ok, view, _html} =
          view
          |> element("[data-test='conversation']")
          |> render_click()
          |> follow_redirect(context.conn)

        # `message-form` with a `message[body]` field — the inbox's own reply
        # form, not a name invented for the criterion.
        view
        |> form("[data-test='message-form']", message: %{body: "yes, right here"})
        |> render_submit()

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the visitor sees his reply in the widget", context do
        # Literal pattern rather than a bound variable: assert_push expands to
        # a receive whose bindings do not escape this step closure. Matching
        # the body inline asserts exactly what the criterion wants — Sam's
        # reply text reaching the visitor's open connection.
        # `new_message`, which is what `ConversationChannel` pushes, with an
        # atom-keyed payload built by `message_payload/1`.
        assert_push("new_message", %{body: "yes, right here"}, 1000)

        {:ok, context}
      end

      then_ "it arrived without the visitor reloading", context do
        # Anchor: the connection that received the push is the same one the
        # visitor opened — a reply that only appears on reload would not
        # have arrived as a push at all.
        assert Process.alive?(context.channel.channel_pid),
               "expected the visitor's original connection to still be the one carrying replies"

        {:ok, context}
      end
    end
  end
end
