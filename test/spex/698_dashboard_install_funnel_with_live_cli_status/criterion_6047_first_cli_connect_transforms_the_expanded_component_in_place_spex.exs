defmodule CodeMySpecSpex.Story698.Criterion6047Spex do
  @moduledoc """
  Story 698 — Dashboard install funnel with live CLI status.
  Criterion 6047 — Rule: First CLI connect while viewing the install
  panel transforms it into a connected state with a "create your first
  story" callout, without navigating the user away.

  Setup: never-connected user on /app with the onboarding card
  expanded. CLI joins Presence for the first time. The component
  transforms in place: pill flips to Connected, a "Next: create your
  first story" callout appears, and the LiveView is not redirected.
  """

  use CodeMySpecSpex.Case
  use Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "First CLI connect transforms the expanded component in place" do
    scenario "First CLI connect transforms the expanded component in place" do
      given_ "the user is on /app", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the onboarding component is expanded and the pill reads Not connected", context do
        assert has_element?(
                 context.view,
                 "[data-test='onboarding-card'][data-state='expanded']"
               ),
               "expected the onboarding card to render expanded for a never-connected user"

        pill = element(context.view, "[data-test='cli-status-pill']") |> render()

        assert pill =~ "Not connected",
               "expected initial pill to read Not connected, got: #{pill}"

        refute has_element?(context.view, "[data-test='next-create-story']"),
               "did not expect the celebrate callout before the first CLI connect"

        {:ok, context}
      end

      when_ "the user's CLI joins Presence for the first time", context do
        {:ok, _reply, channel_socket} =
          CodeMySpecWeb.UserSocket
          |> socket("cli:#{context.user.id}", %{user_id: context.user.id})
          |> subscribe_and_join(
            CodeMySpecWeb.CliChannel,
            "cli:user:#{context.user.id}",
            %{}
          )

        wait_for_channel(channel_socket)
        {:ok, Map.put(context, :channel_socket, channel_socket)}
      end

      then_ "the pill flips to Connected", context do
        pill = element(context.view, "[data-test='cli-status-pill']") |> render()
        assert pill =~ "Connected"
        refute pill =~ "Not connected"
        {:ok, context}
      end

      then_ "the local-workspace callout appears within the component", context do
        assert has_element?(context.view, "[data-test='next-create-story']"),
               "expected the celebrate callout (data-test='next-create-story') in the transformed component"

        callout = element(context.view, "[data-test='next-create-story']") |> render()

        assert String.downcase(callout) =~ "local workspace",
               "expected the celebrate callout to point the user at the local workspace; got: #{callout}"

        assert callout =~ "http://localhost:4003",
               "expected the celebrate callout to link to the local app at localhost:4003"

        {:ok, context}
      end

      then_ "the LiveView has not been navigated away", context do
        # If the LV had redirected, render/1 would raise. Confirm the card
        # is still mounted at the same place by re-asserting its presence.
        assert has_element?(context.view, "[data-test='onboarding-card']"),
               "expected the onboarding card to remain mounted after first CLI connect"

        {:ok, context}
      end
    end
  end
end
