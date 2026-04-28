defmodule CodeMySpecSpex.Story607.Criterion5527Spex do
  @moduledoc """
  Story 607 — New user reaches a working app state without seeing the
  account picker.
  Criterion 5527 — Rule: /app/accounts/picker is reachable via explicit
  user navigation. The page itself must still render — the no-redirect
  invariant applies to automatic redirect chains, not to the route
  itself.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user
  setup :setup_active_account

  spex "Direct visit to /app/accounts/picker renders the picker" do
    scenario "Authenticated user manually navigates to the picker" do
      given_ "the user has an active account", context do
        {:ok, context}
      end

      when_ "the user manually navigates to /app/accounts/picker", context do
        {:ok, view, html} = live(context.conn, "/app/accounts/picker")
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the picker page renders with the account list", context do
        assert context.html =~ "Select Account",
               "expected the picker UI to render on direct navigation"

        assert has_element?(context.view, "[phx-click='account-selected']"),
               "expected at least one selectable account row on the picker"

        {:ok, context}
      end
    end
  end
end
