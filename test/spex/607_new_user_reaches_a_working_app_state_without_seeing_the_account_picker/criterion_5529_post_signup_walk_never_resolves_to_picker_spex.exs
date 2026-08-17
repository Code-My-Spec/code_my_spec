defmodule CodeMySpecSpex.Story607.Criterion5529Spex do
  @moduledoc """
  Story 607 — New user reaches a working app state without seeing the
  account picker.
  Criterion 5529 — Rule: A post-signup walk through /app and gated
  routes never resolves to /app/accounts/picker via automatic redirect.

  This is the integration view of the no-auto-redirect-to-picker
  invariant. The existence guard (/app/projects) redirects to
  /app, and /app itself surfaces the wizard's empty state — at no point
  does the redirect chain visit the picker.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "Post-signup walk through guarded routes never resolves to the picker" do
    scenario "/app and /app/projects never redirect to the picker" do
      given_ "the user is freshly authenticated with zero accounts and zero projects",
             context do
        {:ok, context}
      end

      when_ "the user walks /app and /app/projects", context do
        {:ok,
         Map.merge(context, %{
           app_result: live(context.conn, "/app"),
           projects_result: live(context.conn, "/app/projects")
         })}
      end

      then_ "/app renders the wizard rather than redirecting to the picker", context do
        assert_app_renders_wizard(context.app_result, context)
      end

      then_ "/app/projects redirects to /app, never the picker", context do
        target = redirect_target!(context.projects_result, "/app/projects")
        assert target == "/app"
        refute target == "/app/accounts/picker"
        {:ok, context}
      end
    end
  end

  defp redirect_target!({:error, {kind, %{to: target}}}, _path)
       when kind in [:redirect, :live_redirect],
       do: target

  defp redirect_target!(other, path),
    do: flunk("expected redirect from #{path}, got: #{inspect(other)}")

  defp assert_app_renders_wizard({:ok, _view, _html}, context), do: {:ok, context}

  defp assert_app_renders_wizard({:error, {_kind, %{to: target}}}, _context),
    do:
      flunk(
        "expected /app to render the wizard for a zero-account user, but got a redirect to: #{inspect(target)}"
      )
end
