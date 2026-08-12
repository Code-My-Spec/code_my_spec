defmodule CodeMySpecSpex.Story973.Criterion8041Spex do
  @moduledoc """
  Story 973 — My app has a working feedback widget
  Criterion 8041 — A visitor's message lands on the other side.

  A message sent through the widget on Sam's site arrives in CodeMySpec
  against Sam's project. The socket connects, the channel carries the
  message, and it is attributed to the right project — a widget that sends
  into the void is worse than no widget, because the visitor believes they
  were heard.

  Surface: the widget socket, connected as a visitor would.
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

  spex "A visitor's message lands on the other side" do
    scenario "a message pushed from the widget arrives against Sam's project" do
      given_ "a visitor has the widget open on Sam's site", context do
        # The app holds the credential, not the visitor. A project id is not
        # one — the socket-token endpoint sits behind `Plugs.AppToken` so the
        # browser is handed something the deploy key never becomes.
        app_token = app_access_token(context.project)

        body =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer " <> app_token)
          |> get("/api/widget/socket_token")
          |> Phoenix.ConnTest.json_response(200)

        # The visitor is whoever the widget says they are. Nothing here names
        # the project; the socket resolves it from the token.
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

        {:ok, Map.put(context, :channel, channel)}
      end

      when_ "they send a message", context do
        ref =
          Phoenix.ChannelTest.push(context.channel, "send_message", %{
            "body" => "the widget works"
          })

        {:ok, Map.put(context, :ref, ref)}
      end

      then_ "it arrives in CodeMySpec against Sam's project", context do
        # The channel acknowledging the push proves acceptance; the real
        # proof that it landed against Sam's project is the next step,
        # observed through the LiveView surface.
        assert_reply(context.ref, :ok, %{}, 1000)

        {:ok, context}
      end

      then_ "Sam can see it on the CodeMySpec side", context do
        {:ok, _view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/inbox")

        assert html =~ "the widget works",
               "expected the visitor's message to be visible against Sam's project"

        {:ok, context}
      end
    end
  end
end
