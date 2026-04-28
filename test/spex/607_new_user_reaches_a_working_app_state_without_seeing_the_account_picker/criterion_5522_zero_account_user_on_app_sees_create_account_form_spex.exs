defmodule CodeMySpecSpex.Story607.Criterion5522Spex do
  @moduledoc """
  Story 607 — New user reaches a working app state without seeing the
  account picker.
  Criterion 5522 — Rule: A zero-account user landing on /app via the
  existence-guard redirect sees the create-account form, not the picker.

  Verifies the wizard surfaces the empty-state UI directly on /app, so
  the user never has to interact with /app/accounts/picker to recover.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "Zero-account user on /app sees the create-account form, not the picker" do
    scenario "User with zero accounts sees the create-account form on /app" do
      given_ "the user is on /app with zero accounts", context do
        {:ok, view, html} = live(context.conn, "/app")
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the create-account form renders", context do
        assert has_element?(context.view, "form#account_form"),
               "expected the create-account form on /app for a zero-account user"

        {:ok, context}
      end

      then_ "the picker page does not render in its place", context do
        refute has_element?(context.view, "[phx-click='account-selected']"),
               "the picker LiveView must not render on /app for a zero-account user"

        {:ok, context}
      end
    end
  end
end
