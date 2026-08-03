defmodule CodeMySpecSpex.Story963.Criterion7960Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7960 — A step's state changes under Sam's eyes.

  A running step's state updates on the page Sam already has open — he
  does not reload to find out what happened, and the next step picks up
  visibly. That is the difference between watching a routine and polling
  a job.

  The assertion deliberately uses the *same* mounted view handle rather
  than re-mounting: a re-mount would pass even if the page never pushed
  an update, which is exactly the behaviour under test.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint


  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers
  # Watching a step change state needs a run that is still going.
  setup :watchable_run

  spex "A step's state changes under Sam's eyes" do
    scenario "the page moves a step to done and picks up the next one" do
      given_ "setup is ready to run", context do
        # The step after the server is held open, because the claim is that Sam
        # *watches* the transition. Scripted steps finish instantly, so without
        # this the state the criterion is about would be gone before the page
        # could show it — and the assertion would be about how fast the test
        # rendered, not about whether the page updates.
        context =
          scripted_run(context, %{
            secrets: fn ->
              Process.sleep(3_000)
              {:ok, []}
            end
          })

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the server step runs to completion", context do
        context.view |> element("[data-test='start-setup']") |> render_click()

        # Waiting for the *next* step to pick up, which is the stronger signal:
        # it can only be running once the server step finished, so one wait
        # covers both halves of the claim. Waiting on the server step alone
        # returned before the page had been told about its successor.
        html = await_step_state(context.view, "secrets", "running")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "Sam sees that step move to done without reloading", context do
        html = context.html

        assert html =~ ~r/data-step="server"[^>]*data-state="done"/,
               "expected the server step to show done on the already-open page"

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the next step moves to running", context do
        assert has_element?(context.view, "[data-test='setup-step'][data-state='running']"),
               "expected the following step to pick up once the server step finished; steps: " <>
                 (render(context.view)
                  |> Floki.parse_document!()
                  |> Floki.find("[data-test='setup-step']")
                  |> Enum.map_join(", ", fn s ->
                    "#{s |> Floki.attribute("data-step") |> List.first()}=#{s |> Floki.attribute("data-state") |> List.first()}"
                  end))

        {:ok, context}
      end
    end
  end
end
