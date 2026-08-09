defmodule CodeMySpecSpex.Story997.Criterion8289Spex do
  @moduledoc """
  Story 997 — I can see what is running on each of my servers
  Criterion 8289 — A backup that never ran is not mistaken for one that failed.

  Three states, not two. "No backups exist" and "backups exist and broke" send
  Sam to different places: one is a thing to turn on, the other a thing to
  fix. Collapsing them into a single red mark loses the only bit that tells
  him which.

  The distinction is already in the data — `provisioning_steps.state`
  separates `not_started` from `errored`, and the errored row carries the
  provider's own message. What is missing is a screen that keeps them apart,
  and this is the screen where it counts: backups is the step nobody notices
  is off until the day it matters.

  Surface: `CodeMySpecWeb.ServerLive.Show` at `/app/servers/:name`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "A backup that never ran is not mistaken for one that failed" do
    scenario "done, never run, and failed are three different marks" do
      given_ "a box whose certificate was made, whose deploy failed, and whose backups never ran",
             context do
        context =
          scripted_run(context, %{
            server: fn ->
              {:ok,
               [
                 %{
                   kind: "server",
                   location: "hetzner/uat-box",
                   identifier: "environment=uat ip=203.0.113.10"
                 }
               ]}
            end,
            tls: fn ->
              {:ok,
               [
                 %{
                   kind: "certificate",
                   location: "https://uat.example.com",
                   identifier: "environment=uat"
                 }
               ]}
            end,
            # Halting here is what leaves backups untouched. A step that never
            # ran is not a step we chose to skip — it is one the run never
            # reached, which is exactly how it happens in life.
            deploy: fn ->
              {:error, "uat is missing SECRET_KEY_BASE — the app refuses to boot without it"}
            end
          })

        # The server step's real write-back, which `scripted_run/2` replaces
        # along with the rest of the step. Without it the box is provisioned
        # and nothing records which environment it carries, so nothing can
        # find it again — the same leak the step halts on in production.
        CodeMySpecSpex.Fixtures.record_environment_server(
          context.scope,
          "uat",
          "uat-box",
          "203.0.113.10"
        )

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view |> element("[data-test='start-setup']") |> render_click()
        await_step_state(view, "deploy", "errored")

        {:ok, context}
      end

      given_ "and the box is linked to his account", context do
        context = stage_servers(context, [provider_server(%{name: "uat-box"})])

        {:ok, view, _html} = live(context.conn, "/app/servers")

        view
        |> element("[data-test='link-server'][phx-value-name='uat-box']")
        |> render_click()

        {:ok, context}
      end

      when_ "he opens that server", context do
        context = stage_containers(context, [])

        {:ok, _view, html} = live(context.conn, "/app/servers/uat-box")

        {:ok, context |> Map.put(:html, html) |> Map.put(:document, Floki.parse_document!(html))}
      end

      then_ "the certificate reads as done", context do
        assert context.document
               |> Floki.find("[data-test='step'][data-key='tls']")
               |> Floki.attribute("data-state") == ["done"]

        {:ok, context}
      end

      then_ "backups read as never run, not as failed", context do
        backups = Floki.find(context.document, "[data-test='step'][data-key='backups']")

        assert backups != [],
               "the step nobody notices is off is missing from the page entirely, " <>
                 "which is the quietest way to be off"

        state = Floki.attribute(backups, "data-state")

        refute state == ["errored"],
               "a step that never ran is being reported as one that broke, which sends " <>
                 "him looking for a failure that never happened"

        assert state == ["not_started"]

        {:ok, context}
      end

      then_ "and the deploy reads as failed, carrying the error it failed with", context do
        deploy = Floki.find(context.document, "[data-test='step'][data-key='deploy']")

        assert Floki.attribute(deploy, "data-state") == ["errored"]

        assert Floki.text(deploy) =~ "SECRET_KEY_BASE",
               "the deploy is marked failed without saying what failed, which is the " <>
                 "one thing he needs to act on it"

        {:ok, context}
      end
    end
  end
end
