defmodule CodeMySpecSpex.Story602.Criterion5365Spex do
  @moduledoc """
  Story 602 — OAuth registration creates a fully provisioned user
  Criterion 5365 — Subsequent OAuth login does not overwrite an existing
  active-account preference.

  When a user who already has a personal account (and has selected a different
  account as active, with an active project under it) signs in via OAuth again,
  the callback must not reset their active-account or active-project preference.
  The user should remain on whichever account+project they had selected.

  `UserPreferences.select_active_account/2` clears `active_project_id` as a
  side effect, so a callback that re-selects the same account on every login
  silently nukes the user's project selection too. This spec exercises both
  axes — account preserved AND project preserved.

  Observable through the public surface: after a second OAuth login, the
  account picker still marks the org account "Current", and the project
  picker still marks the previously-selected project "Current". The picker
  emits the "Current" badge only next to the active item — a weaker
  `html =~ name` assertion would pass even after the preference flipped,
  because both accounts appear in the list.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.OAuthHelpers
  alias CodeMySpecSpex.Fixtures


  spex "Subsequent OAuth login does not overwrite an existing active-account preference" do
    scenario "returning Google user keeps their org account and project as active" do
      given_ "an existing user has selected an org account and project as active", context do
        unique = System.unique_integer([:positive])
        email = "returning-5365-#{unique}@example.com"

        user = Fixtures.user_fixture(%{email: email})
        org_account = Fixtures.account_with_owner_fixture(user)
        org_scope = Fixtures.user_scope_fixture(user, org_account)
        project = Fixtures.project_fixture(org_scope, %{name: "Org Project 5365 #{unique}"})

        # Persist active account first — select_active_account nulls active_project_id
        # by design, so we set the project after the account.
        Fixtures.select_active_account(org_scope, org_account.id)
        Fixtures.select_active_project(org_scope, project.id)

        user_claims = %{
          "sub" => "google-sub-5365-#{unique}",
          "email" => email,
          "email_verified" => true,
          "name" => "Returning Google User"
        }

        {:ok,
         Map.merge(context, %{
           email: email,
           user_claims: user_claims,
           org_account: org_account,
           project: project
         })}
      end

      when_ "the user signs in via Google OAuth", context do
        unique = System.unique_integer([:positive])

        cassette_name = "google_5365_#{unique}"
        OAuthHelpers.build_google_cassette!(cassette_name, context.user_claims)

        second_conn =
          OAuthHelpers.do_google_callback(
            build_conn(),
            cassette_name,
            "state-5365"
          )

        {:ok, Map.put(context, :second_conn, second_conn)}
      end

      then_ "the callback redirects to /app, not /app/onboarding (returning user path)",
            context do
        destination = redirected_to(context.second_conn)

        # A returning user (:existing status) is not sent to onboarding.
        # The controller does not put_session(:user_return_to, onboarding) for
        # :existing users.
        refute destination == "/app/onboarding",
               "expected returning user not to be sent to onboarding again"

        :ok
      end

      then_ "the session reaches an account-protected route without a picker detour",
            context do
        user_token_2 = Plug.Conn.get_session(context.second_conn, :user_token)
        assert user_token_2 != nil, "second login must produce a session token"

        # /app/projects is gated by require_active_account. If the previously
        # chosen org account is still the active preference, the LV mounts;
        # if the OAuth callback overwrote the preference (e.g. reset to
        # personal), the on_mount hook redirects to the picker.
        result =
          context.second_conn
          |> recycle()
          |> live("/app/projects")

        case result do
          {:ok, _view, _html} ->
            :ok

          {:error, {kind, %{to: to}}} when kind in [:live_redirect, :redirect] ->
            if to =~ "picker" do
              flunk(
                "active-account preference was overwritten; " <>
                  "got picker redirect after second OAuth login to #{inspect(to)}"
              )
            else
              flunk("unexpected #{kind} to #{inspect(to)} after second OAuth login")
            end

          other ->
            flunk("unexpected live/2 result: #{inspect(other)}")
        end
      end

      then_ "the account picker marks the org account as currently active, not the personal one",
            context do
        {:ok, _view, html} =
          context.second_conn
          |> recycle()
          |> live("/app/accounts/picker")

        assert active_li_text(html, context.org_account.name) =~ "Current",
               "expected the org account to carry the 'Current' badge after a second OAuth login; " <>
                 "if the personal account got the badge instead, the OAuth callback " <>
                 "overwrote the active-account preference."

        :ok
      end

      then_ "the project picker still shows the previously-selected project as currently active",
            context do
        # select_active_account/2 nulls active_project_id as a side effect.
        # If the OAuth callback re-selected the active account on every login,
        # the project would silently disappear from the preference even when
        # the same account was chosen.
        {:ok, _view, html} =
          context.second_conn
          |> recycle()
          |> live("/app/projects/picker")

        assert active_li_text(html, context.project.name) =~ "Current",
               "expected the previously-selected project to carry the 'Current' badge; " <>
                 "if active_project_id is nil, no project will have the badge — that means " <>
                 "the OAuth callback ran select_active_account, which clears active_project_id."

        :ok
      end
    end
  end

  # Both pickers render a `<div class="badge badge-primary">Current</div>` only
  # inside the <li> for the currently-active item. Find the <li> containing
  # `label` and return its text — callers assert the text contains "Current".
  defp active_li_text(html, label) do
    {:ok, doc} = Floki.parse_document(html)

    doc
    |> Floki.find("li")
    |> Enum.find(&(Floki.text(&1) =~ label))
    |> case do
      nil -> ""
      li -> Floki.text(li)
    end
  end
end
