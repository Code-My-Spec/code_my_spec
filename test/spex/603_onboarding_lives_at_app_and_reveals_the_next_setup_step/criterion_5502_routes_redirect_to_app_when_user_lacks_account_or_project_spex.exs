defmodule CodeMySpecSpex.Story603.Criterion5502Spex do
  @moduledoc """
  Story 603 — Onboarding lives at /app and reveals the next setup step.
  Criterion 5502 — Rule: Routes that require an account or a project,
  when the user lacks either, redirect to /app so the wizard can guide
  them through the missing step.

  One scenario, because only one side of the gate is left: a zero-account
  user visiting an account-required route (/app/projects) → 302 to /app.

  The project half of this rule is gone. It existed because the active
  project lived in the user's scope, so a project-scoped page could be
  reached with nothing selected and would break. Projects are named in
  the URL now — there is no such thing as visiting a project route
  without a project, and naming one you can't reach renders a
  not-found message rather than bouncing you to a picker.

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

  end
end
