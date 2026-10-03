defmodule CodeMySpecSpex.Story963.Criterion7971Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7971 — Sam retries one errored step without re-running the rest.

  The status page offers a retry per step, and using it runs only that
  step. The other steps stay exactly as they were — a retry that
  re-executed the whole plan would re-touch working infrastructure to fix
  one broken piece.

  Retargeted onto the console (provisioning-console-step6, unmerged): the
  console has no `start-setup` whole-run cascade to stop at email with
  everything before it already done, so this runs one other step
  (`:repository`) by hand instead of the whole plan — enough to prove a
  single-step retry leaves an unrelated step untouched, without needing
  every step the old page's own run happened to reach first. The retry
  button itself (`[data-test='retry-step']`) is unchanged.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "Sam retries one errored step without re-running the rest", criterion: 576 do
    scenario "retrying the errored step leaves every other step untouched" do
      given_ "the status page shows the email step errored and another step done", context do
        context =
          scripted_run(context, %{
            email:
              first_then(
                fn -> {:error, "Resend rejected the sending domain"} end,
                fn -> {:ok, []} end
              )
          })

        {:ok, repository_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/repository")

        run_console_step(repository_view, :repository)

        assert render(repository_view) =~ ~r/data-step="repository"[^>]*data-state="done"/,
               "expected the repository step to be done before email is attempted"

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/mail")

        run_console_step(view, :email)

        before = render(view)

        assert before =~ ~r/data-step="email"[^>]*data-state="errored"/,
               "expected the email step to error on its first run"

        {:ok, context |> Map.put(:view, view) |> Map.put(:before, before)}
      end

      when_ "Sam retries the email step", context do
        context.view
        |> element("[data-test='resource-step'][data-step='email'] [data-test='retry-step']")
        |> render_click()

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "the email step moves to done", context do
        assert context.html =~ ~r/data-step="email"[^>]*data-state="done"/,
               "expected the retried step to succeed"

        {:ok, context}
      end

      then_ "every other step is exactly as it was", context do
        refute context.html =~ ~r/data-step="inbound"[^>]*data-state="(running|done|errored)"/,
               "expected the retry not to touch inbound, the other step in email's own group"

        {:ok, repository_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/repository")

        assert render(repository_view) =~ ~r/data-step="repository"[^>]*data-state="done"/,
               "expected the unrelated repository step to still be done, untouched by email's retry"

        {:ok, context}
      end
    end
  end
end
