defmodule CodeMySpecSpex.Story607.Criterion5521Spex do
  @moduledoc """
  Story 607 — New user reaches a working app state without seeing the
  account picker.
  Criterion 5521 — Rule: The :require_at_least_one_account guard
  redirects users with zero accounts to /app, not the picker.

  Visits /app/projects (gated by require_at_least_one_account) and
  asserts the redirect target is /app, explicitly refuting the picker.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "Zero-account user visiting a guarded route is redirected to /app" do
    scenario "User with zero accounts is redirected to /app from /app/projects" do
      given_ "the user is logged in with zero accounts", context do
        {:ok, context}
      end

      when_ "the user visits /app/projects", context do
        result = live(context.conn, "/app/projects")
        {:ok, Map.put(context, :result, result)}
      end

      then_ "the existence guard redirects to /app, not the picker", context do
        assert {:error, {kind, %{to: target}}} = context.result,
               "expected a redirect from /app/projects, got: #{inspect(context.result)}"

        assert kind in [:redirect, :live_redirect],
               "expected redirect-style navigation, got: #{inspect(kind)}"

        assert target == "/app",
               "expected target /app, got: #{inspect(target)}"

        refute target == "/app/accounts/picker",
               "the existence guard must never resolve to the picker"

        {:ok, context}
      end
    end
  end
end
