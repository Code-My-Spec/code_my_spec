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
          subscribe_and_join(socket, "conversation:visitor-probe", %{})

        {:ok, Map.put(context, :channel, channel)}
      end

      when_ "they send a message", context do
        ref =
          Phoenix.ChannelTest.push(context.channel, "message", %{
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
          live(context.conn, "/app/projects/#{context.project.id}/conversations")

        assert html =~ "the widget works",
               "expected the visitor's message to be visible against Sam's project"

        {:ok, context}
      end
    end
  end
end
