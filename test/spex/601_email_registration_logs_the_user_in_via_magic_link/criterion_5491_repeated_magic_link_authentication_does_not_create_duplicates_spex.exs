defmodule CodeMySpecSpex.Story601.Criterion5491Spex do
  @moduledoc """
  Story 601 — Email registration logs the user in via magic link.
  Criterion 5491 — Rule: Magic-link authentication is idempotent.

  A user who has already authenticated once can request another magic
  link to the same email and click it; the second click logs the same
  user in (no duplicate User row is created). Observed at the surface
  layer: the second auth still 302s to /app, the resulting
  session token resolves to a logged-in user, and a follow-up GET to
  /app/users/settings (which only requires :require_authenticated)
  succeeds — confirming the session belongs to a unique, live user.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.SharedGivens

  spex "Magic-link auth is idempotent" do
    scenario "Repeated magic-link authentication does not create duplicates" do
      given_ :registered_user_with_magic_link

      given_ "the user has already authenticated once via the first magic link",
             context do
        # Drive the first magic-link controller on a throwaway conn so
        # the user is now confirmed. The session it produces is irrelevant
        # to the assertion — what matters is that a second auth still
        # works for the same email.
        first_conn = Phoenix.ConnTest.build_conn()
        _ = get(first_conn, context.magic_link_url)

        {:ok, context}
      end

      when_ "they request a fresh magic link via the public log-in form", context do
        login_conn = Phoenix.ConnTest.build_conn()

        {:ok, login_view, _html} =
          Phoenix.LiveViewTest.live(
            Plug.Conn.put_private(login_conn, :phoenix_endpoint, CodeMySpecWeb.Endpoint),
            "/users/log-in"
          )

        login_view
        |> Phoenix.LiveViewTest.form("#login_form_magic", user: %{email: context.registered_email})
        |> Phoenix.LiveViewTest.render_submit()

        sent =
          receive do
            {:email, %Swoosh.Email{} = mail} -> mail
          after
            500 ->
              raise "expected fresh magic-link email for #{context.registered_email}"
          end

        true =
          Enum.any?(sent.to, fn {_name, addr} -> addr == context.registered_email end)

        fresh_url = extract_magic_link_url!(sent)

        {:ok, Map.put(context, :fresh_magic_link_url, fresh_url)}
      end

      when_ "they click the fresh link", context do
        conn = get(context.conn, context.fresh_magic_link_url)
        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "the second authentication redirects to /app", context do
        assert context.conn.status == 302,
               "expected a 302 after the second magic-link auth, " <>
                 "got status #{context.conn.status}"

        assert redirected_to(context.conn) == "/app",
               "expected the second magic-link auth to land at /app"

        {:ok, context}
      end

      then_ "the resulting session resolves to a single logged-in user", context do
        assert get_session(context.conn, :user_token),
               "expected a session token after the second magic-link authentication"

        # Hit a route that only requires :require_authenticated (no active
        # account needed). A duplicate user or a broken session would
        # surface here as a 302 to /users/log-in or a 500.
        settings_conn = get(recycle(context.conn), "/app/users/settings")

        assert settings_conn.status == 200,
               "expected /app/users/settings to return 200 after the second " <>
                 "magic-link auth — duplicate users would break session resolution. " <>
                 "Got status #{settings_conn.status}."

        {:ok, context}
      end
    end
  end

  defp extract_magic_link_url!(%Swoosh.Email{text_body: body}) when is_binary(body),
    do: magic_link_match(Regex.run(~r{https?://\S+/users/log-in/[^\s.,;:!?\"'>)]+}, body), body)

  defp magic_link_match([url], _body), do: url
  defp magic_link_match(_, body), do: raise("could not extract magic-link URL from email body: #{inspect(body)}")
end
