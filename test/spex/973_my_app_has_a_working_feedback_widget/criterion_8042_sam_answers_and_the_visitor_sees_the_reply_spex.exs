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

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam answers and the visitor sees the reply" do
    scenario "a reply from CodeMySpec is pushed to the open widget" do
      given_ "a visitor's message has arrived", context do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/widget/socket_token", %{"project_id" => context.project.id})

        body = Phoenix.ConnTest.json_response(conn, 200)

        {:ok, socket} =
          Phoenix.ChannelTest.connect(
            CodeMySpecWeb.WidgetSocket,
            %{"token" => body["token"]},
            %{}
          )

        {:ok, _reply, channel} =
          Phoenix.ChannelTest.subscribe_and_join(socket, "conversation:visitor-probe", %{})

        ref = Phoenix.ChannelTest.push(channel, "message", %{"body" => "is anyone there"})
        Phoenix.ChannelTest.assert_reply(ref, :ok, %{}, 1000)

        {:ok, Map.put(context, :channel, channel)}
      end

      when_ "Sam replies from CodeMySpec", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/conversations")

        view
        |> form("[data-test='conversation-reply-form']", reply: %{body: "yes, right here"})
        |> render_submit()

        {:ok, Map.put(context, :view, view)}
      end

      then_ "the visitor sees his reply in the widget", context do
        # Literal pattern rather than a bound variable: assert_push expands to
        # a receive whose bindings do not escape this step closure. Matching
        # the body inline asserts exactly what the criterion wants — Sam's
        # reply text reaching the visitor's open connection.
        Phoenix.ChannelTest.assert_push("message", %{"body" => "yes, right here"}, 1000)

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
