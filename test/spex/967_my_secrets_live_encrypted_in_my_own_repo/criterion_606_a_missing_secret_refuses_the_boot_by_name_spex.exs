defmodule CodeMySpecSpex.Story967.Criterion8000Spex do
  @moduledoc """
  Story 967 — My secrets live encrypted in my own repo
  Criterion 8000 — A missing secret refuses the boot by name.

  A required secret absent from the environment file stops the boot and
  names the missing key. Booting half-configured is worse than not
  booting: the app comes up, serves requests, and fails on whatever code
  path needed the secret — at which point the cause is far from the
  symptom.

  Retargeted onto the console (provisioning-console-step6, unmerged): see
  criterion 605's moduledoc for the same move — secrets on
  `/console/secrets`, deploy on its own `/console/deploys` page. Unlike
  every other step, `run_step_with_environment` always dispatches the
  deploy through `Provisioning.run_step_async/3` regardless of the
  `provisioning_run_async` test setting, so `render_submit/1` returns
  before the run settles — the same reason the old page's
  `run_step_interaction(view, :deploy)` was always paired with an
  `await_step/3`. `await_operation/3` stands in for that here.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Sops`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  defp deploy_settled?(html) do
    Regex.match?(
      ~r/data-test="deploy-row"[^>]*data-environment="uat"[^>]*data-state="(done|errored)"/,
      html
    )
  end

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_working_directory
  setup :fake_providers

  spex "A missing secret refuses the boot by name", criterion: 606 do
    scenario "the boot fails naming the absent key rather than starting anyway" do
      given_ "a required secret is absent from the environment's file", context do
        # One environment, because the secret below is set for `uat` and the
        # deploy step fans out over every environment the project has. With
        # production present the run reached it first and reported "prod has no
        # age key yet" — a missing *key*, not the missing *secret* this
        # criterion is about.
        #
        # `only_environments/2` rather than `devops: :uat`: environments are
        # rows, and `Environments.list_deployment/1` seeds both from a fixed list
        # on first read regardless of the devops level. Removing the row is
        # what turning production off actually means.
        only_environments(context.scope, ["uat"])

        # The claim is that a *missing secret* is named, so the missing secret
        # has to be the only thing wrong. Without the boilerplate the deploy
        # step refuses earlier and correctly — "this project is not
        # deploy-ready: missing Dockerfile, …" — and the criterion would be
        # asserting about a run that never reached the secrets at all.
        deploy_ready_checkout(context)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/secrets")

        # Deliberately set only one of the required secrets, leaving
        # SECRET_KEY_BASE absent. Not clearing it afterwards — it was never
        # supplied.
        open_secrets_dialog(view)

        view
        |> form("[data-test='secret-form']",
          secret: %{key: "DATABASE_URL", value: "ecto://...", environment: "uat"}
        )
        |> render_submit()

        {:ok, deploys_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/deploys?env=uat")

        {:ok, Map.put(context, :view, deploys_view)}
      end

      when_ "the app boots", context do
        context.view
        |> form(
          "[data-test='deploy-row'][data-step='deploy'][data-environment='uat'] [data-test='deploy-environment-form']",
          %{"environment" => "uat"}
        )
        |> render_submit()

        html = await_operation(context.view, &deploy_settled?/1, &deploy_settled?/1)

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
