defmodule CodeMySpecSpex.Story965.Criterion7992Spex do
  @moduledoc """
  Story 965 — My domain is registered and pointed at my app
  Criterion 7992 — Sam finds the domain in his own account.

  The domain is registered into Sam's own Cloudflare account, under his
  ownership, with nothing held on the platform's side. He can leave
  CodeMySpec tomorrow and keep his domain — that is the whole premise of
  provisioning into the user's own accounts.

  Observably: the setup record names the account the domain landed in, and
  it is Sam's, not a platform account.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Cloudflare`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @register_cassette "cloudflare_domain_register_ok"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam finds the domain in his own account" do
    scenario "the registered domain is recorded under Sam's own account" do
      given_ "setup registered the domain Sam confirmed", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        ReqCassette.with_cassette(@register_cassette, [mode: :replay], fn ->
          view
          |> form("[data-test='domain-form']", domain: %{name: "sams-new-thing.com"})
          |> render_submit()

          view |> element("[data-test='confirm-purchase']") |> render_click()
        end)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam looks at where the domain lives", context do
        html =
          context.view
          |> element("[data-test='provisioned-resource'][data-kind='domain']")
          |> render()

        {:ok, Map.put(context, :resource, html)}
      end

      then_ "it is under his own account", context do
        parsed = Floki.parse_document!(context.resource)

        owner =
          parsed
          |> Floki.attribute("data-owner")
          |> List.first()

        assert owner == "user",
               "expected the domain to be recorded as owned by Sam, got #{inspect(owner)}"

        location = parsed |> Floki.attribute("data-location") |> List.first()

        assert is_binary(location) and location != "",
               "expected the record to name the account the domain lives in"

        {:ok, context}
      end

      then_ "nothing about it is held on the platform's side", context do
        refute context.resource =~ ~r/data-owner="platform"/,
               "expected no part of the domain to be held by the platform"

        {:ok, context}
      end
    end
  end
end
