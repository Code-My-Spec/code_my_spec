defmodule CodeMySpecSpex.Story607.Criterion5524Spex do
  @moduledoc """
  Story 607 — New user reaches a working app state without seeing the
  account picker.
  Criterion 5524 — Rule: The :require_active_account guard auto-picks
  the first account regardless of how many accounts the user has —
  multi-account scope still bypasses the picker.

  Setup fixtures two owned accounts and leaves active_account=nil to
  exercise the guard's selection branch under multi-account scope.
  Visiting /app/projects must render without redirecting to
  /app/accounts/picker.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  setup %{user: user} do
    first = Fixtures.account_with_owner_fixture(user, %{name: "Workspace A"})
    second = Fixtures.account_with_owner_fixture(user, %{name: "Workspace B"})
    {:ok, %{first_account: first, second_account: second}}
  end

  spex "Multi-account user with no active selection still bypasses the picker" do
    scenario "User with multiple accounts auto-picks the first instead of seeing the picker" do
      given_ "the user has two accounts but no active selection", context do
        {:ok, context}
      end

      when_ "the user visits /app/projects", context do
        result = live(context.conn, "/app/projects")
        {:ok, Map.put(context, :result, result)}
      end

      then_ "the projects index renders without any redirect to the picker", context do
        assert_renders_not_redirect(context.result, context)
      end
    end
  end

  defp assert_renders_not_redirect({:ok, _view, _html}, context), do: {:ok, context}

  defp assert_renders_not_redirect({:error, {_kind, %{to: target}}}, _context),
    do:
      flunk(
        "expected /app/projects to render after auto-account-selection, but got a redirect to: #{inspect(target)}"
      )
end
