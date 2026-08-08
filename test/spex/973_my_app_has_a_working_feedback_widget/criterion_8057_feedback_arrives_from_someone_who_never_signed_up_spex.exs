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
        # No user session, no identity — only the project's public widget
        # token, which is what a script tag on a public page can obtain.
        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/widget/socket_token", %{"project_id" => context.project.id})

        body = Phoenix.ConnTest.json_response(conn, 200)

        assert is_binary(body["token"]),
               "expected an anonymous visitor to be able to obtain a widget token"

        {:ok, Map.put(context, :token, body["token"])}
      end

      when_ "they open the widget and send a message", context do
        {:ok, socket} =
          Phoenix.ChannelTest.connect(
            CodeMySpecWeb.WidgetSocket,
            %{"token" => context.token},
            %{}
          )

        {:ok, _reply, channel} =
          subscribe_and_join(socket, "conversation:anonymous-probe", %{})

        ref =
          Phoenix.ChannelTest.push(channel, "message", %{
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
          live(context.conn, "/app/projects/#{context.project.id}/conversations")

        assert html =~ "never signed up but here is my feedback",
               "expected the anonymous visitor's feedback to be visible to Sam"

        {:ok, context}
      end
    end
  end
end
