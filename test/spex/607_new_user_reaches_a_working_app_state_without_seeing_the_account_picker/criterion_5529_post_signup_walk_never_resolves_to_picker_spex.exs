defmodule CodeMySpecSpex.Story607.Criterion5529Spex do
  @moduledoc """
  Story 607 — New user reaches a working app state without seeing the
  account picker.
  Criterion 5529 — Rule: A post-signup walk through /app and gated
  routes never resolves to /app/accounts/picker via automatic redirect.

  This is the integration view of the no-auto-redirect-to-picker
  invariant. Existence guards (/app/projects, /app/issues) redirect to
  /app, and /app itself surfaces the wizard's empty state — at no point
  does the redirect chain visit the picker.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "Post-signup walk through guarded routes never resolves to the picker" do
    scenario "/app, /app/projects, and /app/issues never redirect to the picker" do
      given_ "the user is freshly authenticated with zero accounts and zero projects",
             context do
        {:ok, context}
      end

      when_ "the user walks /app, /app/projects, /app/issues", context do
        app_result = live(context.conn, "/app")
        projects_result = live(context.conn, "/app/projects")
        stories_result = live(context.conn, "/app/issues")

        {:ok,
         Map.merge(context, %{
           app_result: app_result,
           projects_result: projects_result,
           stories_result: stories_result
         })}
      end

      then_ "/app renders the wizard rather than redirecting to the picker", context do
        case context.app_result do
          {:ok, _view, _html} ->
            {:ok, context}

          {:error, {_kind, %{to: target}}} ->
            flunk(
              "expected /app to render the wizard for a zero-account user, " <>
                "but got a redirect to: #{inspect(target)}"
            )
        end
      end

      then_ "/app/projects redirects to /app, never the picker", context do
        target = redirect_target!(context.projects_result, "/app/projects")
        assert target == "/app"
        refute target == "/app/accounts/picker"
        {:ok, context}
      end

      then_ "/app/issues redirects to /app, never the picker", context do
        target = redirect_target!(context.stories_result, "/app/issues")
        assert target == "/app"
        refute target == "/app/accounts/picker"
        {:ok, context}
      end
    end
  end

  defp redirect_target!(result, path) do
    case result do
      {:error, {kind, %{to: target}}} when kind in [:redirect, :live_redirect] ->
        target

      other ->
        flunk("expected redirect from #{path}, got: #{inspect(other)}")
    end
  end
end
