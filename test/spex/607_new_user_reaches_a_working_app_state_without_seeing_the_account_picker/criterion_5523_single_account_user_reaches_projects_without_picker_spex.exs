defmodule CodeMySpecSpex.Story607.Criterion5523Spex do
  @moduledoc """
  Story 607 — New user reaches a working app state without seeing the
  account picker.
  Criterion 5523 — Rule: The :require_active_account guard auto-picks
  the first account in scope on success and continues silently — never
  redirecting to the picker.

  Setup creates one owned account but does NOT set it active, so the
  guard's auto-pick branch fires when the user visits /app/projects.
  The projects index should render directly with no detour through
  /app/accounts/picker.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  setup %{user: user} do
    account = Fixtures.account_with_owner_fixture(user, %{name: "Solo Workspace"})
    {:ok, %{first_account: account}}
  end

  spex "Single-account user with no active selection auto-advances past the picker" do
    scenario "User with one account loads /app/projects without seeing the picker" do
      given_ "the user has one account but no active selection", context do
        {:ok, context}
      end

      when_ "the user visits /app/projects", context do
        result = live(context.conn, "/app/projects")
        {:ok, Map.put(context, :result, result)}
      end

      then_ "the projects index renders without any redirect to the picker", context do
        case context.result do
          {:ok, _view, _html} ->
            {:ok, context}

          {:error, {_kind, %{to: target}}} ->
            flunk(
              "expected /app/projects to render after auto-account-selection, " <>
                "but got a redirect to: #{inspect(target)}"
            )
        end
      end
    end
  end
end
