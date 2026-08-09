defmodule CodeMySpecSpex.Story973.Criterion8057Spex do
  @moduledoc """
  Story 973 — My app has a working feedback widget
  Criterion 8057 — Feedback arrives from someone who never signed up.

  A visitor who has not signed in can open the widget and send a message,
  and it reaches CodeMySpec. Sam's call: the most useful feedback comes from
  people who bounced before signing up, and requiring identity loses exactly
  those voices.

  The consequence is an open channel, so abuse handling is a real concern —
  it belongs to the widget product rather than to setup and is deliberately
  not specified here.

  Surface: the widget socket, connected as an anonymous visitor.
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

  spex "Feedback arrives from someone who never signed up" do
    scenario "an anonymous visitor's message reaches CodeMySpec" do
      given_ "a visitor who has not signed in is on Sam's site", context do
        # The app holds the token, not the visitor. A script tag on a public
        # page cannot be handed anything that names a project — the customer's
        # own server already carries the app token and exchanges it for a
        # short-lived, browser-safe socket token. The visitor's browser is
        # given that and nothing else: no project id, no account, no identity
        # it had to create.
        #
        # An earlier draft of this criterion posted a `project_id` to get a
        # token, which would mean anyone who can read a project id out of a URL
        # can open a socket against that project. The endpoint is behind
        # `Plugs.AppToken` deliberately; the router says so.
        # Provisioning hands the app a refresh secret (the callback-credential
        # step); the app exchanges it for a short-lived access token. Doing it
        # that way here rather than reaching for a private mint keeps the spex
        # on the same path the deployed app takes.
        app_token = app_access_token(context.project)

        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer " <> app_token)
          |> get("/api/widget/socket_token")

        body = Phoenix.ConnTest.json_response(conn, 200)

        assert is_binary(body["socket_token"]),
               "expected the app's token to mint a browser-safe socket token"

        {:ok, Map.put(context, :socket_token, body["socket_token"])}
      end

      when_ "they open the widget and send a message", context do
        # The visitor is whoever the widget says they are — an id and an email
        # it generated for them. Nothing here names the project; the socket
        # resolves that from the token the app supplied.
        visitor = "visitor-#{System.unique_integer([:positive])}"

        {:ok, socket} =
          Phoenix.ChannelTest.connect(
            CodeMySpecWeb.WidgetSocket,
            %{
              "socket_token" => context.socket_token,
              "user_id" => visitor,
              "user_email" => "#{visitor}@example.com"
            },
            %{}
          )

        {:ok, _reply, channel} = subscribe_and_join(socket, "conversation:#{visitor}", %{})

        ref =
          Phoenix.ChannelTest.push(channel, "send_message", %{
            "body" => "never signed up but here is my feedback"
          })

        {:ok, context |> Map.put(:channel, channel) |> Map.put(:ref, ref)}
      end

      then_ "it reaches CodeMySpec", context do
        # Acceptance on the channel; the proof it is visible to Sam is the
        # next step, observed through the LiveView surface.
        assert_reply(context.ref, :ok, %{}, 1000)

        {:ok, context}
      end

      then_ "Sam hears from someone who would otherwise have left silently", context do
        {:ok, _view, html} =
          # A plain path, not `~p`. The sigil binds its router at compile time and
          # this module's is the local one, so `~p` checks a route table that
          # does not own the inbox — the cloud router does, under `/app`.
          live(context.conn, "/app/projects/#{context.project.id}/inbox")

        assert html =~ "never signed up but here is my feedback",
               "expected the anonymous visitor's feedback to be visible to Sam"

        {:ok, context}
      end
    end
  end
end
