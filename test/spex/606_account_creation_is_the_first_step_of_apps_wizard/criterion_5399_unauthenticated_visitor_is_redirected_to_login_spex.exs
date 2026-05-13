defmodule CodeMySpecSpex.Story606.Criterion5399Spex do
  @moduledoc """
  Story 606 — Account creation is the first step of /app's wizard.
  Criterion 5399 — An unauthenticated visitor to /app is redirected to
  the login page before any onboarding form is rendered.

  The other 606 spex assume an authenticated user (`register_and_log_in_user`).
  This one stays on the cloud endpoint with a fresh `build_conn/0` — no
  session, no user — and asserts the LiveView mount short-circuits to
  the auth surface instead of rendering onboarding state.

  Surface: cloud LiveView (`CodeMySpecWeb.Endpoint`). The assertion is
  on the mount result tuple: an unauthenticated `live/2` call returns
  `{:error, {:redirect, %{to: "/users/log-in", ...}}}` (or the
  equivalent live-redirect shape) rather than `{:ok, view, html}`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  spex "Unauthenticated visitor is redirected to login before /app renders" do
    scenario "live/2 on /app without auth returns a redirect to the login page" do
      given_ "an unauthenticated conn", context do
        {:ok, Map.put(context, :conn, Phoenix.ConnTest.build_conn())}
      end

      when_ "the visitor mounts /app", context do
        {:ok, Map.put(context, :mount_result, live(context.conn, "/app"))}
      end

      then_ "the mount returns a redirect, not a rendered onboarding view",
            context do
        assert {:error, {kind, %{to: target}}} = context.mount_result,
               "expected a redirect from /app when unauthenticated, got: #{inspect(context.mount_result)}"

        assert kind in [:redirect, :live_redirect],
               "expected a redirect-style mount failure, got: #{inspect(kind)}"

        assert target =~ "/users/log-in",
               "expected redirect target to be the login page, got: #{target}"

        {:ok, context}
      end
    end
  end
end
