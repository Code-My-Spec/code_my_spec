defmodule CodeMySpecSpex.Story969.Criterion8056Spex do
  @moduledoc """
  Story 969 — My app sends mail from my own domain
  Criterion 8056 — Test mail cannot pass for production mail.

  Amended 2026-08. The guarantee is unchanged; the mechanism is not. This used
  to be "each environment sends from its own subdomain" — production from the
  main domain, UAT from its own — so the two could never be confused. Sam's
  later call was simpler: only production sends at all. UAT has no sending
  domain, no verification and no reputation, which makes test mail that could
  pass for production mail not merely distinguishable but impossible.

  `Steps.mail_environments/2` is where that lives: it filters the project's
  environments down to production before the email step does anything.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "Test mail cannot pass for production mail" do
    scenario "only production is set up to send" do
      given_ "a project with both environments", context do
        # Its own subdomain. Every criterion in this story used one shared name,
        # so whichever ran second found the first's sending domain already
        # registered and *adopted* it — and an adopted resource is never torn
        # down. Recorded alone each one passed; run together they replayed each
        # other's state.
        #
        # Production only, matching what the step will do. Publishing UAT's
        # records here would set up the very thing this criterion says is not
        # set up, and the assertions below would then be reading the fixture's
        # work rather than the step's.
        # The zone the records go into. Under a cassette this was true because
        # John's Cloudflare manages `astralbi.com`; stated here, so publishing
        # a record means it resolves.
        zone_exists(context, "astralbi.com")

        project = own_domain(context.project, "c8056.astralbi.com")
        verified_sending_domains(context.scope, project, ["prod"])
        tear_down_after(context.scope, [:email])

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        # The *updated* project, not the one setup made. `own_domain/2` returns
        # a new struct rather than mutating, so a later step reading
        # `context.project.domain` gets the nil it was created with and
        # compares the step's correct answer against nothing.
        {:ok, context |> Map.put(:view, view) |> Map.put(:project, project)}
      end

      when_ "the email step has run", context do
        context.view
        |> element("[data-test='setup-step'][data-step='email'] [data-test='run-step']")
        |> render_click()

        # The page *after* the run, not what the click handed back. A step
        # announces itself with `{:provisioning, :step, …}`, and the
        # sections this criterion reads are assigned when that arrives —
        # which is after the event `render_click/1` returns from. Its
        # return value therefore shows the page before anything was
        # recorded, and an empty section reads as "nothing happened".
        html = render(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "production has a sending domain", context do
        by_env =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='mail-sending-domain']")
          |> Map.new(fn el ->
            {el |> Floki.attribute("data-environment") |> List.first(),
             el |> Floki.attribute("data-domain") |> List.first()}
          end)

        # Anchor: the step recorded a sending domain at all. Without this, the
        # refutation below is satisfied by a step that did nothing, which is
        # the same page as a step that correctly did production only.
        assert by_env["prod"] not in [nil, ""],
               "expected production to have a sending domain, got #{inspect(by_env)}"

        {:ok, Map.put(context, :by_env, by_env)}
      end

      then_ "UAT has none, so it cannot send anything to be mistaken", context do
        refute Map.has_key?(context.by_env, "uat"),
               "expected no sending domain for UAT, got #{inspect(context.by_env)}"

        {:ok, context}
      end

      then_ "production sends from Sam's own domain rather than a test one", context do
        prod = context.by_env["prod"]

        assert prod == context.project.domain,
               "expected production to send from the project's own domain #{inspect(context.project.domain)}, got #{inspect(prod)}"

        {:ok, context}
      end
    end
  end
end
