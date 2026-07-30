defmodule CodeMySpecSpex.Story963.Criterion7965Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7965 — Running a step twice leaves one of everything.

  Steps converge rather than accumulate. Running the server step a second
  time leaves one server and one firewall, and reports success — it does
  not error out complaining the resources already exist, and it does not
  create duplicates Sam then pays for.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @create_cassette "hetzner_server_create_ok"
  @converge_cassette "hetzner_server_create_idempotent"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Running a step twice leaves one of everything" do
    scenario "a second run of the server step converges instead of duplicating" do
      given_ "the server step already provisioned a server and a firewall", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        ReqCassette.with_cassette(@create_cassette, [mode: :replay], fn ->
          view
          |> element("[data-test='setup-step'][data-step='server'] [data-test='run-step']")
          |> render_click()
        end)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the server step runs a second time", context do
        ReqCassette.with_cassette(@converge_cassette, [mode: :replay], fn ->
          context.view
          |> element("[data-test='setup-step'][data-step='server'] [data-test='run-step']")
          |> render_click()
        end)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "the step reports success rather than an already-exists error", context do
        assert context.html =~ ~r/data-step="server"[^>]*data-state="done"/,
               "expected the repeated run to succeed, not error on existing resources"

        refute context.html =~ ~r/data-step="server"[^>]*data-state="errored"/,
               "expected no already-exists failure on the second run"

        {:ok, context}
      end

      then_ "the record shows one server and one firewall", context do
        resources =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource']")
          |> Enum.map(&(Floki.attribute(&1, "data-kind") |> List.first()))

        # Anchor: resources are recorded at all, so the counts below mean
        # something.
        assert resources != [], "expected the run to record provisioned resources"

        assert Enum.count(resources, &(&1 == "server")) == 1,
               "expected exactly one server after two runs, got #{inspect(resources)}"

        assert Enum.count(resources, &(&1 == "firewall")) == 1,
               "expected exactly one firewall after two runs, got #{inspect(resources)}"

        {:ok, context}
      end
    end
  end
end
