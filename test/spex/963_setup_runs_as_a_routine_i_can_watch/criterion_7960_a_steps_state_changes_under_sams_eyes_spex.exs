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

  @cassette "hetzner_server_create_ok"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A step's state changes under Sam's eyes" do
    scenario "the server step moves to done on the open page, and the next starts" do
      given_ "Sam is watching the status page with setup ready to run", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the server step runs to completion", context do
        ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
          context.view
          |> element("[data-test='setup-step'][data-step='server'] [data-test='run-step']")
          |> render_click()
        end)

        {:ok, context}
      end

      then_ "Sam sees that step move to done without reloading", context do
        html = render(context.view)

        assert html =~ ~r/data-step="server"[^>]*data-state="done"/,
               "expected the server step to show done on the already-open page"

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the next step moves to running", context do
        assert has_element?(context.view, "[data-test='setup-step'][data-state='running']"),
               "expected the following step to pick up once the server step finished"

        {:ok, context}
      end
    end
  end
end
