defmodule CodeMySpecSpex.Story700.Criterion6058Spex do
  @moduledoc """
  Story 700 — Onboarding workflow guides me from signup to the local application.
  Criterion 6058 — Rule: The fourth step is a navigation handoff to
  the local application — clicking it opens the local workspace in a
  new browser tab so the dashboard remains in place.

  Once all prerequisites are met (account + project + a CLI has
  connected at least once), the application rung renders as an
  anchor pointing at the local workspace URL with `target="_blank"`
  and `rel="noopener"`.
  """

  use CodeMySpecSpex.Case
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Active application step opens the local workspace in a new tab" do
    scenario "Active application step opens the local workspace in a new tab" do
      given_ "the user has had a CLI join Presence at some point", context do
        {:ok, _reply, channel_socket} =
          CodeMySpecWeb.UserSocket
          |> socket("cli:#{context.user.id}", %{user_id: context.user.id})
          |> subscribe_and_join(
            CodeMySpecWeb.CliChannel,
            "cli:user:#{context.user.id}",
            %{}
          )

        wait_for_channel(channel_socket)
        {:ok, context}
      end

      given_ "the user mounts /app", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "the application rung is rendered as an anchor to the local workspace", context do
        # Href may optionally carry a `?project=<id>` handoff suffix
        # (story 701 / S3 — lands the user on the per-project ladder
        # instead of the picker). Anchor on the prefix, not the exact URL.
        assert has_element?(
                 context.view,
                 "a[data-test='application-rung'][href^='http://localhost:4003']"
               ),
               "expected application-rung to be an anchor pointing at http://localhost:4003"

        {:ok, context}
      end

      then_ "the anchor opens in a new tab without leaking the opener", context do
        rendered = element(context.view, "[data-test='application-rung']") |> render()

        assert rendered =~ ~s|target="_blank"|,
               "expected application-rung anchor to carry target=\"_blank\""

        assert rendered =~ "noopener",
               "expected application-rung anchor's rel attribute to include 'noopener'"

        {:ok, context}
      end
    end
  end
end
