defmodule CodeMySpecSpex.Story607.Criterion5519Spex do
  @moduledoc """
  Story 607 — New user reaches a working app state without seeing the
  account picker.
  Criterion 5519 — Rule: The post-auth redirect target is /app, never
  /app/accounts/picker.

  Drives the public registration LiveView, captures the magic link from
  the test mailbox, and confirms the magic-link controller redirects to
  /app — explicitly refuting the picker.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "Magic-link confirmation lands the user on /app, never the picker" do
    scenario "Magic-link confirmation redirects to /app" do
      given_ :registered_user_with_magic_link

      when_ "the user clicks the magic link", context do
        conn = get(context.conn, context.magic_link_url)
        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "the redirect target is /app and never the picker", context do
        assert context.conn.status == 302,
               "expected 302 after magic-link confirm, got #{context.conn.status}"

        target = redirected_to(context.conn)

        assert target == "/app",
               "expected redirect to /app, got: #{inspect(target)}"

        refute target == "/app/accounts/picker",
               "post-auth redirect must never resolve to the picker"

        {:ok, context}
      end
    end
  end
end
