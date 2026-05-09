defmodule CodeMySpecSpex.Story603.Criterion5502Spex do
  @moduledoc """
  Story 603 — Onboarding lives at /app and reveals the next setup step.
  Criterion 5502 — Rule: Routes that require an account or a project,
  when the user lacks either, redirect to /app so the wizard can guide
  them through the missing step.

  Two scenarios — one per side of the gate:

  - Zero-account user visiting an account-required route (/app/projects)
    → 302 to /app
  - Account but zero projects, visiting a project-required route
    (/app/issues) → 302 to /app

  The rendering of the wizard at /app is covered separately by criteria
  5499 / 5500. This spec just confirms the redirect contract.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  spex "Routes redirect to /app when the user lacks account or project" do
    scenario "User with no accounts is redirected to /app from an account-required route" do
      given_ "a logged-in user with zero accounts", context do
        %{conn: conn, user: user, scope: scope} =
          register_and_log_in_user(%{conn: context.conn})

        {:ok, Map.merge(context, %{conn: conn, user: user, scope: scope})}
      end

      when_ "the user visits /app/projects", context do
        result = live(context.conn, "/app/projects")
        {:ok, Map.put(context, :result, result)}
      end

      then_ "the response is a redirect to /app", context do
        assert {:error, {kind, %{to: target}}} = context.result,
               "expected a redirect from /app/projects, got: #{inspect(context.result)}"

        assert kind in [:redirect, :live_redirect],
               "expected redirect-style navigation, got: #{inspect(kind)}"

        assert target == "/app", "expected target /app, got: #{inspect(target)}"

        {:ok, context}
      end
    end

    scenario "User with account but no projects is redirected to /app from a project-required route" do
      given_ "a logged-in user with an active account but zero projects", context do
        context =
          %{conn: context.conn}
          |> register_and_log_in_user()
          |> setup_active_account()

        {:ok, Map.merge(context, context)}
      end

      when_ "the user visits /app/issues", context do
        result = live(context.conn, "/app/issues")
        {:ok, Map.put(context, :result, result)}
      end

      then_ "the response is a redirect to /app", context do
        assert {:error, {kind, %{to: target}}} = context.result,
               "expected a redirect from /app/issues, got: #{inspect(context.result)}"

        assert kind in [:redirect, :live_redirect],
               "expected redirect-style navigation, got: #{inspect(kind)}"

        assert target == "/app", "expected target /app, got: #{inspect(target)}"

        {:ok, context}
      end
    end
  end
end
