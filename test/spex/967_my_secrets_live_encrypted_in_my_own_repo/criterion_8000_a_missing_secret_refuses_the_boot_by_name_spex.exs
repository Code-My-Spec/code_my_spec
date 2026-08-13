defmodule CodeMySpecSpex.Story967.Criterion8000Spex do
  @moduledoc """
  Story 967 — My secrets live encrypted in my own repo
  Criterion 8000 — A missing secret refuses the boot by name.

  A required secret absent from the environment file stops the boot and
  names the missing key. Booting half-configured is worse than not
  booting: the app comes up, serves requests, and fails on whatever code
  path needed the secret — at which point the cause is far from the
  symptom.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Sops`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "kamal_deploy_boot_missing_secret"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :real_working_directory
  setup :connect_providers

  spex "A missing secret refuses the boot by name" do
    scenario "the boot fails naming the absent key rather than starting anyway" do
      given_ "a required secret is absent from the environment's file", context do
        # One environment, because the secret below is set for `uat` and the
        # deploy step fans out over every environment the project has. With
        # production present the run reached it first and reported "prod has no
        # age key yet" — a missing *key*, not the missing *secret* this
        # criterion is about.
        #
        # `only_environments/2` rather than `devops: :uat`: environments are
        # rows, and `EnvironmentRepository.list/1` seeds both from a fixed list
        # on first read regardless of the devops level. Removing the row is
        # what turning production off actually means.
        only_environments(context.scope, ["uat"])

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        # Deliberately set only one of the required secrets, leaving
        # SECRET_KEY_BASE absent. Not clearing it afterwards — it was never
        # supplied.
        view
        |> form("[data-test='secret-form']",
          secret: %{key: "DATABASE_URL", value: "ecto://...", environment: "uat"}
        )
        |> render_submit()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the app boots", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='deploy'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it refuses to start", context do
        assert context.html =~ ~r/data-step="deploy"[^>]*data-state="errored"/,
               "expected the deploy to fail rather than bring up a half-configured app"

        {:ok, context}
      end

      then_ "it names the missing secret rather than running half-configured", context do
        failure =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='boot-failure']")
          |> Floki.text()

        assert failure =~ "SECRET_KEY_BASE",
               "expected the missing key to be named, got: #{inspect(failure)}"

        {:ok, context}
      end
    end
  end
end
