defmodule CodeMySpecSpex.Story971.Criterion8055Spex do
  @moduledoc """
  Story 971 — My deployed app talks back to CodeMySpec without a long-lived key
  Criterion 8055 — A visitor mid-conversation notices no expiry.

  The widget's socket re-authenticates in place when its token lapses: the
  connection stays open and the conversation continues. Sam's chosen
  alternative — drop and reconnect — would lose a visitor's half-typed
  message every time a short token expired, which is the cost that made
  re-auth worth the extra protocol work.

  Surface: the widget socket, connected as a visitor would.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A visitor mid-conversation notices no expiry" do
    scenario "the socket re-authenticates in place and the conversation continues" do
      given_ "a visitor has the widget open and the connection's token is about to lapse",
              context do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/token", %{"refresh_secret" => "refresh-secret"})

        body = Phoenix.ConnTest.json_response(conn, 200)

        {:ok, socket} =
          Phoenix.ChannelTest.connect(
            CodeMySpecWeb.WidgetSocket,
            %{"token" => body["access_token"]},
            %{}
          )

        {:ok, _reply, channel} =
          Phoenix.ChannelTest.subscribe_and_join(
            socket,
            "conversation:visitor-probe",
            %{}
          )

        # Anchor: the conversation is live before expiry is in play.
        ref = Phoenix.ChannelTest.push(channel, "message", %{"body" => "before expiry"})
        Phoenix.ChannelTest.assert_reply(ref, :ok, %{}, 1000)

        {:ok,
         context
         |> Map.put(:channel, channel)
         |> Map.put(:expires_in, body["expires_in"])}
      end

      when_ "the token expires", context do
        ref =
          Phoenix.ChannelTest.push(context.channel, "clock_advance", %{
            "seconds" => context.expires_in + 60
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, %{}, 1000)

        {:ok, context}
      end

      then_ "the connection presents a fresh one and stays open", context do
        Phoenix.ChannelTest.refute_push("disconnect", %{}, 300)

        assert Process.alive?(context.channel.channel_pid),
               "expected the socket to stay open across the renewal rather than dropping"

        {:ok, context}
      end

      then_ "the visitor's conversation continues uninterrupted", context do
        ref = Phoenix.ChannelTest.push(context.channel, "message", %{"body" => "after expiry"})

        Phoenix.ChannelTest.assert_reply(ref, :ok, %{}, 1000)

        {:ok, context}
      end
    end
  end
end
