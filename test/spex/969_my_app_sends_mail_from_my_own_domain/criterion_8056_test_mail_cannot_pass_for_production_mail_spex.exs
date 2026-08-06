defmodule CodeMySpecSpex.Story969.Criterion8056Spex do
  @moduledoc """
  Story 969 — My app sends mail from my own domain
  Criterion 8056 — Test mail cannot pass for production mail.

  Each environment sends from its own subdomain: production from the main
  domain, UAT from its own. So test mail can never be mistaken for real
  mail, and a UAT sending-reputation problem cannot touch the domain
  production depends on.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "resend_sending_domains_per_environment"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "Test mail cannot pass for production mail" do
    scenario "each environment has its own sending domain" do
      given_ "both environments can send", context do
        # Its own subdomain. Every criterion in this story used one shared name,
        # so whichever ran second found the first's sending domain already
        # registered and *adopted* it — and an adopted resource is never torn
        # down. Recorded alone each one passed; run together they replayed each
        # other's state.
        project = own_domain(context.project, "c8056.astralbi.com")
        verified_sending_domains(context.scope, project)
        tear_down_after(context.scope, [:email])

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the email step has run for each", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='email'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "production sends from the main domain and UAT from its own subdomain", context do
        by_env =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='mail-sending-domain']")
          |> Map.new(fn el ->
            {el |> Floki.attribute("data-environment") |> List.first(),
             el |> Floki.attribute("data-domain") |> List.first()}
          end)

        # Anchor: sending domains were recorded per environment.
        assert map_size(by_env) >= 2,
               "expected a sending domain per environment, got #{inspect(by_env)}"

        prod = by_env["prod"]
        uat = by_env["uat"]

        assert is_binary(prod) and is_binary(uat),
               "expected both environments to name their sending domain, got #{inspect(by_env)}"

        refute prod == uat,
               "expected UAT and production to send from different domains, both #{inspect(prod)}"

        assert String.ends_with?(uat, prod),
               "expected UAT's sending domain to be a subdomain of the main one, got uat=#{inspect(uat)} prod=#{inspect(prod)}"

        {:ok, Map.put(context, :by_env, by_env)}
      end

      then_ "a reputation problem on one does not touch the other", context do
        # Distinct verified domains mean distinct reputation. Same-domain
        # sending with only a differing From local-part would not.
        verified =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='mail-sending-domain']")
          |> Enum.map(&(Floki.attribute(&1, "data-verified-separately") |> List.first()))

        assert Enum.all?(verified, &(&1 == "true")),
               "expected each environment's sending domain to be verified in its own right, got #{inspect(verified)}"

        {:ok, context}
      end
    end
  end
end
