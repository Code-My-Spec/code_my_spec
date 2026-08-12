defmodule CodeMySpecSpex.Story998.Criterion8296Spex do
  @moduledoc """
  Story 998 — I can tell at a glance whether my whole setup is healthy
  Criterion 8296 — A backup that was never set up is on the checklist as missing.

  The half of the page that cannot be built from an inventory. Everything a
  provider reports is something that *exists*; nothing a provider reports tells
  you what *should* exist and does not. That comes from the sequence, and it is
  the whole reason this is a checklist rather than a list.

  Backups is the example because it is the one that hurts. A project with no
  backups looks identical to one with backups, right up until the morning it
  does not, and there is no resource to notice the absence of.

  The entry has to appear because the checklist knows the account should have
  it — not because a `provisioning_steps` row happens to exist. A step that was
  never reached has no row at all, which is exactly the state being tested.

  Surface: `CodeMySpecWeb.ResourceLive.Index` at `/app/resources`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "A backup that was never set up is on the checklist as missing" do
    scenario "the checklist names what should be there and is not" do
      given_ "a project Sam has said is meant to be deployed", context do
        # Said explicitly, through the page that says it. DevOps is opt-in —
        # every project is a project and only some are meant to have
        # infrastructure — so a checklist that appeared without this would be
        # demanding servers of things nobody intends to deploy.
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/configuration")

        view
        |> form("[data-test='configuration-form']", %{"configuration" => %{"devops" => "prod"}})
        |> render_submit()

        {:ok, context}
      end

      # The server, and not also the certificate: `Sequence` puts `tls` after
      # `deploy`, and a failing step halts the run rather than pressing on
      # (7961). Scripting a `tls` that the run can never reach made this
      # criterion assert that an unreachable step had run — the scripted
      # function was never called, and "tls was made and the checklist does not
      # say so" was the page telling the truth.
      given_ "whose server exists", context do
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
            # Halting here is what leaves backups untouched — not skipped, but
            # never reached, which is how it happens in life and which leaves
            # no row behind to read.
            deploy: fn -> {:error, "the app refuses to boot without SECRET_KEY_BASE"} end
          })

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view |> element("[data-test='start-setup']") |> render_click()
        await_step_state(view, "deploy", "errored")

        {:ok, context}
      end

      when_ "he opens the resources page", context do
        context = stage_inventory(context, %{hetzner: [], cloudflare: [], resend: []})

        {:ok, view, _html} = live(context.conn, "/app/resources")

        {:ok, context |> Map.put(:document, Floki.parse_document!(render_async(view)))}
      end

      then_ "backups appear on the checklist, marked missing", context do
        backups = Floki.find(context.document, "[data-test='checklist-item'][data-key='backups']")

        assert backups != [],
               "the thing nobody notices is off is not on the checklist, which is the " <>
                 "quietest way for it to stay off"

        assert Floki.attribute(backups, "data-state") == ["missing"]

        {:ok, context}
      end

      then_ "it is there because the checklist knows what is expected, not because a record exists",
            context do
        # A step the run never reached writes no row. If the entry only showed
        # up when a row existed, this one could not be on the page at all.
        assert Floki.find(context.document, "[data-test='checklist-item'][data-key='monitoring']") != [],
               "only steps with a persisted row are being listed, so the checklist can " <>
                 "never report something that was never started"

        {:ok, context}
      end

      # The control on the two above: without something reading `present`, a
      # checklist that marked everything `missing` would satisfy them both.
      then_ "and the server appears as present", context do
        item = Floki.find(context.document, "[data-test='checklist-item'][data-key='server']")

        assert Floki.attribute(item, "data-state") == ["present"],
               "the server was made and the checklist does not say so"

        {:ok, context}
      end
    end
  end
end
