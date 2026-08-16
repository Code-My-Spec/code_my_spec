defmodule CodeMySpecSpex.Story841.Criterion1966Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1966 — A missing secret fails the boot loudly and by name.

  Two claims, and the second is the one that matters. An app missing a secret
  must refuse to start rather than come up half-configured — and it must say
  *which* secret, because "boot failed" sends someone reading logs for the one
  variable nobody set.

  Surface: `ProvisioningLive`, running the deploy against an environment whose
  encrypted env file is short a required key.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "841_1966_missing_secret_refuses_boot"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  # `sops` and `age` are real binaries reading real files, and the default
  # fixture installs a memory environment they cannot see — the encrypt reports
  # success and the file is never anywhere. This criterion decrypts, so it
  # needs a directory that exists:
  #
  #   {:sops_failed, 100, "cannot operate on non-existent file .../envs/uat.enc.env"}
  #
  # It went unnoticed while the deploy stopped at an earlier check and never
  # reached the decrypt.
  setup :fake_working_directory
  setup :fake_providers

  spex "A missing secret fails the boot loudly and by name" do
    scenario "the environment is short a required secret" do
      given_ "Sam is on the setup page and UAT is missing a required secret", context do
        # One environment. The deploy step fans out over every environment the
        # project has, so with production present this stopped being about a
        # missing *secret*: the run reached prod, which has no age key at all,
        # and reported "prod has no age key yet" — the very refusal the comment
        # below is careful to get past for UAT.
        #
        # `only_environments/2` rather than `devops: :uat`: environments are
        # rows, and `EnvironmentRepository.list/1` seeds both from a fixed list
        # on first read whatever the devops level says.
        only_environments(context.scope, ["uat"])

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        # UAT has its age key and the boot secret the step now mints, and
        # nothing else. Without the key the deploy
        # stops one check earlier — "uat has no age key yet — set a secret, or
        # run the secrets step, before deploying" — which is a different
        # refusal about a different missing thing, and it is what this
        # criterion was actually observing.
        #
        # The secrets step is what mints the key, so running it is the premise:
        # a project that has been through setup and simply never had this
        # secret set.
        run_steps(view, [:secrets], @cassette <> "_setup")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the deploy runs", context do
        context.view
        |> element("[data-test='setup-step'][data-step='deploy'] [data-test='run-step']")
        |> render_click()

        html = render(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the boot is refused rather than started half-configured", context do
        failure =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='boot-failure']")
          |> Floki.text()

        assert failure =~ "refuses to boot",
               "expected the app to refuse rather than start without its configuration, got: #{failure}"

        {:ok, context}
      end

      then_ "the missing secret is named", context do
        failure =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='boot-failure']")
          |> Floki.text()

        # DATABASE_URL, not SECRET_KEY_BASE. The secrets step mints the boot
        # secret now — Phoenix refuses a `secret_key_base` shorter than 64
        # bytes, and a project that had an age key but no boot secret failed
        # the deploy by name two steps later. So the secret still absent after
        # the step is the database URL.
        #
        # Which one is incidental to the claim: this criterion is that a
        # missing secret is *named*, so someone can set it, rather than the app
        # coming up half-configured.
        assert failure =~ "DATABASE_URL",
               "expected the missing key to be named so it can be set, got: #{failure}"

        {:ok, context}
      end
    end
  end
end
