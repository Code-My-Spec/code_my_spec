defmodule CodeMySpecSpex.Story964.Criterion8051Spex do
  @moduledoc """
  Story 964 — My provider credentials go in once and get checked
  Criterion 8051 — Another project's credentials are not reachable.

  Credentials are scoped to the account that owns them, and an account is where
  a provider credential means something: a Hetzner token names a Hetzner
  account, and the boxes it reaches outlive any one project (`48a6e127`, "the
  same grain as the servers they name"). Two projects on one account therefore
  *do* share a token, deliberately — keying it per project is what made the
  servers page depend on which project happened to be open.

  So the isolation this criterion is about is between accounts. A user with two
  accounts must not have one account's run reaching for the other's keys — the
  second account's intake starts empty even though the first is populated.

  Rewritten from a two-project check to a two-account one after QA on story 850
  found the form still writing per project while the runtime read per account
  (`bcd2b2b4`). The old shape passed only because the write was going somewhere
  nothing read.

  Surface: the provisioning page on the cloud app.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Another project's credentials are not reachable" do
    scenario "a second project's intake is empty while the first is populated" do
      given_ "the first project has a credential stored", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view
        |> element("[data-test='manage-credentials']")
        |> render_click()

        view
        |> form("[data-test='credentials-form']",
          credentials: %{hetzner_api_token: "first-project-token"}
        )
        |> render_submit()

        {:ok, context}
      end

      given_ "Sam also owns a second account, with a project on it", context do
        second_account = Fixtures.account_with_owner_fixture(context.user, %{name: "Globex"})
        second_scope = Fixtures.user_scope_fixture(context.user, second_account)

        second_project =
          Fixtures.project_fixture(second_scope, %{name: "Globex Site", module_name: "GlobexSite"})

        {:ok,
         context
         |> Map.put(:second_project, second_project)
         |> Map.put(:second_account_id, second_account.id)}
      end

      when_ "he opens credential entry for the project on the other account", context do
        # Through the picker, because the page reads the *active* account and
        # switching it is what a user with two accounts actually does.
        {:ok, picker, _html} = live(context.conn, "/app/accounts/picker")

        picker
        |> element("a[phx-value-account-id='#{second_account_id(context)}']")
        |> render_click()

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.second_project.id}/provisioning")

        html =
          view
          |> element("[data-test='manage-credentials']")
          |> render_click()

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "the first account's credential is not there", context do
        # Anchor: intake rendered for the second project, so the absence
        # below is real rather than an empty page.
        assert has_element?(context.view, "[data-test='credentials-form']"),
               "expected the second account's credential intake to render"

        refute has_element?(
                 context.view,
                 "[data-test='credential-field'][data-credential='hetzner_api_token'][data-stored='true']"
               ),
               "expected the second account to hold no credential of its own"

        refute context.html =~ "first-project-token",
               "expected the first account's value never to surface on another account"

        {:ok, context}
      end
    end
  end

  defp second_account_id(context), do: context.second_account_id
end
