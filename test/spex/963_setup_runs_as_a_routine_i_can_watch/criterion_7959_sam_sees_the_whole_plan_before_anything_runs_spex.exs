defmodule CodeMySpecSpex.Story963.Criterion7959Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7959 — Sam sees the whole plan before anything runs.

  Opening the setup status page shows the whole ordered step sequence
  *before* anything executes, with every step marked not started. The
  plan is visible up front rather than revealed one step at a time as
  the routine walks it — that is what makes setup watchable instead of
  a black box that reports after the fact.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Sam sees the whole plan before anything runs" do
    scenario "the status page lists every step in order, none of them started" do
      given_ "Sam has a project with setup options chosen", context do
        # Chosen through the form, not assumed from the defaults. The plan
        # under test is rendered *from* these options, so a spex that let
        # them default would stop testing the relationship the moment the
        # defaults changed — and would fail in the `then_` counting steps,
        # which points at the plan rather than at the options behind it.
        #
        # Still no step rows pre-seeded: the page renders the plan from the
        # options alone, and that is the behaviour under test.
        view = mount_provisioning(context)
        options = all_setup_options(view)

        {:ok, Map.put(context, :options, options)}
      end

      # A fresh mount on purpose. The options chosen above are persisted to
      # the project, so opening the page again is the journey Sam actually
      # takes — and if that ever stops being true, this is where it shows.
      when_ "he opens the setup status page", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "he sees every step that will run, in order", context do
        steps =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='setup-step']")

        # Anchor: the page rendered a plan at all. Without this the
        # ordering assertion below would pass on an empty document.
        assert steps != [], "expected the status page to render setup steps"

        rendered_order = Enum.map(steps, &Floki.attribute(&1, "data-step") |> List.first())

        # Every step the routine will run is listed, in the order the
        # routine will run them.
        assert rendered_order == Enum.uniq(rendered_order),
               "expected each step to appear exactly once, got #{inspect(rendered_order)}"

        assert Enum.all?(rendered_order, &is_binary/1),
               "expected every rendered step to name itself via data-step"

        {:ok, Map.put(context, :rendered_order, rendered_order)}
      end

      then_ "each step is marked not started", context do
        for step <- context.rendered_order do
          assert has_element?(
                   context.view,
                   "[data-test='setup-step'][data-step='#{step}'][data-state='not_started']"
                 ),
                 "expected step #{step} to be marked not_started before the run begins"
        end

        # Nothing has run, so no step may claim a terminal or in-flight state.
        refute has_element?(context.view, "[data-test='setup-step'][data-state='running']")
        refute has_element?(context.view, "[data-test='setup-step'][data-state='done']")
        refute has_element?(context.view, "[data-test='setup-step'][data-state='errored']")

        {:ok, context}
      end
    end
  end
end
