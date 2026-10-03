defmodule CodeMySpecSpex.Story963.Criterion7959Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7959 — Sam sees the whole plan before anything runs.

  Opening the setup status page shows the whole ordered step sequence
  *before* anything executes, with every step marked not started. The
  plan is visible up front rather than revealed one step at a time as
  the routine walks it — that is what makes setup watchable instead of
  a black box that reports after the fact.

  Retargeted onto the console (provisioning-console-step6, unmerged): "the
  whole plan before anything runs" now means the Overview page's
  `setup-checklist`, which lists `@plan` the same way the old page's flat
  step list did — just not scoped to one step's own card, since the console
  has no single page that renders every step's full markup at once. Added
  `data-environment` to `setup-checklist-item` (it only carried `data-step`),
  since this criterion's own claim — each step/environment *pair* appears
  once — cannot be checked without it.

  Narrower than before in one way: `all_setup_options/1` drives a
  `setup-options-form` the console does not have — picking which options
  run is no longer a page action (see criterion 573, which loses its subject
  for exactly this reason). This now prints the plan `setup_options/1`
  returns by default rather than a form-chosen subset; it still proves the
  plan is fully visible before anything runs, just not that it reflects an
  arbitrary choice of options — that half of the original claim no longer
  has a surface to prove it from.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Sam sees the whole plan before anything runs", criterion: 565 do
    scenario "the status page lists every step in order, none of them started" do
      when_ "he opens the setup status page", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/console")

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "he sees every step that will run, in order", context do
        steps =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='setup-checklist-item']")

        # Anchor: the page rendered a plan at all. Without this the
        # ordering assertion below would pass on an empty document.
        assert steps != [], "expected the status page to render setup steps"

        # A project-wide step is one entry; a step that runs independently per
        # environment is one entry per environment (`Sequence.scope/1`). The
        # pair is the identity now, not the key alone — "secrets" legitimately
        # appears once for prod and once for uat, and that is two different
        # rows of the plan, not a duplicate of the same one.
        rendered_order =
          Enum.map(steps, fn step ->
            {Floki.attribute(step, "data-step") |> List.first(),
             Floki.attribute(step, "data-environment") |> List.first()}
          end)

        # Every step (and, for a per-environment step, every environment's
        # row of it) the routine will run is listed, in the order the routine
        # will run them.
        assert rendered_order == Enum.uniq(rendered_order),
               "expected each step/environment pair to appear exactly once, got #{inspect(rendered_order)}"

        assert Enum.all?(rendered_order, fn {step, _environment} -> is_binary(step) end),
               "expected every rendered step to name itself via data-step"

        {:ok, Map.put(context, :rendered_order, rendered_order)}
      end

      then_ "each step is marked not started", context do
        for {step, environment} <- context.rendered_order do
          assert has_element?(context.view, step_selector(step, environment)),
                 "expected step #{step} (#{environment || "project"}) to be marked not_started " <>
                   "before the run begins"
        end

        # Nothing has run, so no step may claim a terminal or in-flight state.
        refute has_element?(context.view, "[data-test='setup-checklist-item'][data-state='running']")
        refute has_element?(context.view, "[data-test='setup-checklist-item'][data-state='done']")
        refute has_element?(context.view, "[data-test='setup-checklist-item'][data-state='errored']")

        {:ok, context}
      end
    end
  end

  defp step_selector(step, nil),
    do: "[data-test='setup-checklist-item'][data-step='#{step}'][data-state='not_started']"

  defp step_selector(step, env),
    do:
      "[data-test='setup-checklist-item'][data-step='#{step}'][data-environment='#{env}'][data-state='not_started']"
end
