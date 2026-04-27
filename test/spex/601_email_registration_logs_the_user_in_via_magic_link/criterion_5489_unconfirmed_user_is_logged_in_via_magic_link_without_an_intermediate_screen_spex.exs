defmodule CodeMySpecSpex.Story601.Criterion5489Spex do
  @moduledoc """
  Story 601 — Email registration creates a fully provisioned user
  Criterion 5489 — Rule: Magic link click both confirms the account and
  logs the user in directly. There is no intermediate "Confirm and stay
  logged in" screen.

  Setup runs the public `/users/register` LiveView through the UI; the
  magic-link email is captured by Swoosh's test adapter; the assertion
  hits the same magic-link route a real user's browser would.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "Magic link click confirms + logs in directly without intermediate screen" do
    scenario "Unconfirmed user is logged in via magic link without an intermediate screen" do
      given_ :registered_user_with_magic_link

      when_ "they click the link", context do
        conn = get(context.conn, context.magic_link_url)
        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "they are logged in directly with no intermediate screen", context do
        assert context.conn.status == 302,
               "expected the magic-link endpoint to 302 the user straight into the app — " <>
                 "no intermediate \"Confirm and stay logged in\" screen. " <>
                 "Got status #{context.conn.status}."

        assert get_session(context.conn, :user_token),
               "expected a session token to be set after the magic-link click, " <>
                 "indicating the user is logged in directly"

        {:ok, context}
      end
    end
  end
end
