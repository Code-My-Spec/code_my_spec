defmodule CodeMySpecSpex.Story601.Criterion5358Spex do
  @moduledoc """
  Story 601 — Email registration creates a fully provisioned user
  Criterion 5358 — Rule: Provisioning is idempotent.

  A user who has already been provisioned via a prior magic-link click
  can authenticate again via a fresh magic link without creating
  duplicate Account, Member, or UserPreference rows.

  Setup uses the public registration LiveView for the first link, then
  drives the public /users/log-in LiveView's magic-link form to issue
  a second link to the same email. The second magic-link click is
  observed through the public surface — reaching /app/accounts cleanly
  (200) means account resolution is still unambiguous after the
  second auth.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import_givens CodeMySpecSpex.SharedGivens

  spex "Provisioning is idempotent" do
    scenario "Repeated magic-link authentication does not create duplicates" do
      given_ :registered_user_with_magic_link

      given_ "the user has already been provisioned by clicking the first magic link",
             context do
        # Drive the magic-link controller once on a throwaway conn so the user
        # gets confirmed + provisioned. The session it produces is irrelevant
        # to the assertion that follows — what matters is the side-effect on
        # the DB.
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

      then_ "the second authentication is accepted with no duplicate-account ambiguity",
            context do
        assert get_session(context.conn, :user_token),
               "expected session token after second magic-link authentication"

        accounts_conn = get(recycle(context.conn), "/app/accounts")

        assert accounts_conn.status == 200,
               "expected /app/accounts to return 200 — duplicates would cause " <>
                 "require_active_account to redirect to the picker. " <>
                 "Got status #{accounts_conn.status}."

        :ok
      end
    end
  end

  defp extract_magic_link_url!(%Swoosh.Email{text_body: body}) when is_binary(body) do
    case Regex.run(~r{https?://\S+/users/log-in/[^\s.,;:!?\"'>)]+}, body) do
      [url] -> url
      _ -> raise "could not extract magic-link URL from email body: #{inspect(body)}"
    end
  end
end
