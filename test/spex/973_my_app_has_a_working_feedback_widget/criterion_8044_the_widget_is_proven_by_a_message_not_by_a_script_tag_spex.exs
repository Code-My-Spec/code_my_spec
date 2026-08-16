defmodule CodeMySpecSpex.Story973.Criterion8044Spex do
  @moduledoc """
  Story 973 — My app has a working feedback widget
  Criterion 8044 — The widget is proven by a message, not by a script tag.

  The widget step confirms a real message travelled from the deployed site
  into CodeMySpec before reporting done. Asserting the script tag is present
  proves the generator ran, not that feedback works — and the failure would
  only surface when a visitor's message vanished.

  Same prove-it-before-claiming-it gate as 968's restore, 972's render and
  974's inbound delivery.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Widget`.
  """

  use CodeMySpecSpex.Case
  # connect/3 and push/3 collide with Phoenix.ConnTest and Plug.Conn, which
  # CodeMySpecSpex.Case also imports. Require + qualify those two; import the
  # rest, since assert_reply is a macro.
  import Phoenix.ChannelTest, except: [connect: 3, push: 3]
  require Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  @site "http://127.0.0.1:4100"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :widget_on_the_fleet

  spex "The widget is proven by a message, not by a script tag" do
    scenario "the step confirms an end-to-end message before reporting done" do
      # Renamed and made true. The old title said the widget step had
      # already configured everything — but that step is what the `when_`
      # runs, so the precondition was describing the thing under test.
      #
      # The message is the premise, not the assertion. The step's job is to
      # *confirm* one arrived before reporting done; making the step also
      # send it would mean the criterion never sees the gate it is about.
      # Sent the way a visitor's browser sends one — the app's token exchanged
      # for a socket token, then the widget socket — so what is being proved is
      # the path a real message takes.
      given_ "Sam's site is deployed and a visitor has sent a message from it", context do
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
              "user_email" => "#{visitor}@example.com",
              # What makes this a message from the deployed site rather than
              # from a laptop holding the same credential. The step compares it
              # against the site it just checked.
              "origin" => @site
            },
            connect_info: %{}
          )

        {:ok, _reply, channel} = subscribe_and_join(socket, "conversation:#{visitor}", %{})

        ref = Phoenix.ChannelTest.push(channel, "send_message", %{"body" => "the widget works"})
        assert_reply(ref, :ok, %{}, 1000)

        view = mount_provisioning(context)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "it verifies itself", context do
        html =
          context.view
          |> element("[data-test='setup-step'][data-step='widget'] [data-test='run-step']")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it confirmed a real message travelled from the site into CodeMySpec", context do
        parsed = Floki.parse_document!(context.html)

        proof = parsed |> Floki.find("[data-test='widget-message-proof']")

        # Anchor: a message proof exists rather than a markup assertion.
        assert proof != [], "expected the widget step to record a message proof"

        state = proof |> Floki.attribute("data-state") |> List.first()
        origin = proof |> Floki.attribute("data-origin") |> List.first()

        assert state == "received",
               "expected an actual received message, got #{inspect(state)}"

        assert origin == "deployed_site",
               "expected the probe message to originate from the deployed site rather than a local harness, got #{inspect(origin)}"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "only then is the step marked done", context do
        assert context.html =~ ~r/data-step="widget"[^>]*data-state="done"/,
               "expected the widget step to be done once a message was proven"

        proven_at =
          context.parsed
          |> Floki.find("[data-test='widget-message-proof']")
          |> Floki.attribute("data-completed-at")
          |> List.first()

        done_at =
          context.parsed
          |> Floki.find("[data-test='setup-step'][data-step='widget']")
          |> Floki.attribute("data-completed-at")
          |> List.first()

        assert is_binary(proven_at) and is_binary(done_at),
               "expected both the proof and the step completion to be timestamped"

        assert proven_at <= done_at,
               "expected the message proof to precede the step being called done: proven_at=#{proven_at} done_at=#{done_at}"

        {:ok, context}
      end
    end
  end
end
