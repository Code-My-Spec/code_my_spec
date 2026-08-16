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

  spex "A visitor mid-conversation notices no expiry" do
    scenario "the socket re-authenticates in place and the conversation continues" do
      # The socket authenticates with a *socket token* (the browser-safe
      # credential minted by `GET /api/widget/socket_token`), not an access
      # token — the two carry different salts on purpose. The visitor's
      # identity travels as connect params, which the conversation join
      # requires.
      given_ "a visitor has the widget open on a fresh socket token", context do
        {token, _expires_in} = mint_socket_token(context.scope)

        {:ok, socket} =
          Phoenix.ChannelTest.connect(
            CodeMySpecWeb.WidgetSocket,
            %{
              "socket_token" => token,
              "user_id" => "visitor-probe",
              "user_email" => "visitor@example.com"
            },
            %{}
          )

        {:ok, _reply, channel} =
          subscribe_and_join(socket, "conversation:visitor-probe", %{})

        # Anchor: the conversation is live before renewal is in play.
        ref = Phoenix.ChannelTest.push(channel, "send_message", %{"body" => "before renewal"})
        assert_reply(ref, :ok, _, 1000)

        {:ok, Map.put(context, :channel, channel)}
      end

      # The token nears its window, so the widget fetches a fresh one and
      # re-authenticates *on the open channel* rather than dropping and
      # reconnecting — a reconnect loses in-flight messages and rejoins from
      # scratch, which the visitor would notice even when it is fast.
      when_ "the widget renews the token in place", context do
        {fresh, _expires_in} = mint_socket_token(context.scope)

        ref = Phoenix.ChannelTest.push(context.channel, "reauth", %{"socket_token" => fresh})
        assert_reply(ref, :ok, %{status: "ok"}, 1000)

        {:ok, context}
      end

      then_ "the connection stays open across the renewal", context do
        refute_push("disconnect", %{}, 300)

        assert Process.alive?(context.channel.channel_pid),
               "expected the socket to stay open across the renewal rather than dropping"

        {:ok, context}
      end

      then_ "the visitor's conversation continues uninterrupted", context do
        ref =
          Phoenix.ChannelTest.push(context.channel, "send_message", %{"body" => "after renewal"})

        assert_reply(ref, :ok, _, 1000)

        {:ok, context}
      end
    end
  end
end
