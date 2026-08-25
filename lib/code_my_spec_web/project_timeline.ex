defmodule CodeMySpecWeb.ProjectTimeline do
  @moduledoc """
  Where a project stands, across the top of its pages.

  The steps are the project's own requirements — John's call, and the reason it
  can be a line at all. A project graph is a sequence: you cannot triage
  problems that do not exist yet. The story work is not a sequence, and the
  screen this replaces got that wrong.

  > "What it got wrong was trying to represent the non-linear story work in a
  > linear process."

  So all of the story work is one step, however many stories are behind it, and
  the per-story detail stays on the page built to show it.

  ## Thirteen steps and "a handful"

  Both, by zoom rather than by cutting. Every requirement is on the line; the
  phase the project is in is expanded and the phases either side are collapsed
  to a mark each. A shorter list would read more easily and could not answer a
  question about a step it left out.

  ## Why a component and not a page

  A page you have to navigate to is a page somebody has to know exists, and
  knowing which of eleven project pages answers "how is it going" is the problem
  this removes. On a page of its own it would be the twelfth.
  """

  use CodeMySpecWeb, :html

  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.PlainLanguage

  @doc """
  The timeline for a project, or nothing at all.

  Nothing when there is no project in scope — every page this rides has one, but
  the layout renders before that is guaranteed and a crash in a header takes
  every page with it.
  """
  attr :scope, :map, required: true
  attr :project, :any, default: nil

  def project_timeline(assigns) do
    assigns = assign(assigns, :steps, steps_for(assigns[:project], assigns.scope))

    ~H"""
    <nav
      :if={@steps != []}
      data-test="project-timeline"
      aria-label="Where this project stands"
      class="border-b border-base-300 bg-base-200/50 px-4 py-2 lg:px-8"
    >
      <ol class="flex items-stretch gap-1 overflow-x-auto">
        <li
          :for={phase <- @steps}
          data-test="timeline-phase"
          data-phase={phase.key}
          data-expanded={to_string(phase.expanded?)}
          class={[
            "flex shrink-0 items-center gap-1 rounded-box px-2 py-1",
            phase.expanded? && "bg-base-100 ring-1 ring-primary/30",
            not phase.expanded? && "opacity-60"
          ]}
        >
          <%!-- The phase's own name, so a collapsed phase is still a word
          rather than an unlabelled mark. --%>
          <span class="text-xs font-semibold uppercase tracking-wide opacity-70">
            {phase.label}
          </span>

          <span
            :for={step <- phase.steps}
            data-test="timeline-step"
            data-step={step.name}
            data-state={step.state}
          >
            <.link navigate={step.path} class="block" title={step.title}>
              <%!-- Expanded: the step's name. Collapsed: a dot, so a phase
              zoomed out still reads as a run of marks with some filled. It
              rendered nothing at all before unless the step was done, which
              made three of five phases bare words — zoomed out, not absent, is
              the whole point of showing the neighbours. --%>
              <span
                :if={phase.expanded?}
                class={[
                  "block rounded-selector px-2 py-1 text-xs",
                  step.state == "current" && "bg-primary text-primary-content font-semibold",
                  step.state == "done" && "opacity-70",
                  step.state == "todo" && "opacity-50"
                ]}
              >
                <.icon :if={step.state == "done"} name="hero-check" class="size-3" />
                {step.title}
              </span>

              <span :if={not phase.expanded?} class="flex items-center px-0.5 py-1">
                <span class={[
                  "size-2 rounded-full",
                  step.state == "current" && "bg-primary",
                  step.state == "done" && "bg-base-content/50",
                  step.state == "todo" && "bg-base-content/20"
                ]}>
                </span>
                <span class="sr-only">{step.title}</span>
              </span>
            </.link>
          </span>
        </li>
      </ol>

      <p :if={current_detail(@steps)} data-test="step-detail" class="mt-1 text-sm opacity-80">
        {current_detail(@steps)}
      </p>
    </nav>
    """
  end

  # The two static sentences, from the one step that is current.
  defp current_detail(phases) do
    phases
    |> Enum.flat_map(& &1.steps)
    |> Enum.find_value(fn step -> step.state == "current" && step.detail end)
  end

  defp steps_for(nil, _scope), do: []

  # A project that has not been saved yet. The new-project form renders this
  # layout with an empty `%Project{}` — truthy, so a presence check passes — and
  # every step would then build a path from a nil id. There is nothing to draw:
  # no requirements have been computed and no page exists to link to.
  defp steps_for(%{id: nil}, _scope), do: []

  defp steps_for(project, scope) do
    satisfied = satisfied_names(scope)
    current = current_step(satisfied)

    PlainLanguage.phases()
    |> Enum.map(fn {key, label} ->
      steps = steps_in_phase(key, project, satisfied, current)

      %{
        key: key,
        label: label,
        steps: steps,
        expanded?: Enum.any?(steps, &(&1.state == "current"))
      }
    end)
    |> Enum.reject(&(&1.steps == []))
  end

  defp steps_in_phase(key, project, satisfied, current) do
    for name <- PlainLanguage.order(),
        meaning = PlainLanguage.fetch(name),
        meaning.phase == key do
      %{
        name: name,
        title: meaning.title,
        detail: meaning.detail,
        state: state_of(name, satisfied, current),
        path: path_for(name, project)
      }
    end
  end

  # Exactly one step is current, always.
  #
  # The first unsatisfied step in the order, and the last step when everything
  # is satisfied. Never none: an idle project is the ordinary overnight state,
  # and a timeline that marks nothing then is indistinguishable from one that
  # failed to load.
  defp current_step(satisfied) do
    Enum.find(PlainLanguage.order(), List.last(PlainLanguage.order()), &(&1 not in satisfied))
  end

  defp state_of(name, _satisfied, current) when name == current, do: "current"
  defp state_of(name, satisfied, _current), do: if(name in satisfied, do: "done", else: "todo")

  # Which of the project's own requirements are met. An empty list when the
  # graph cannot answer — a timeline that shows everything as not-started is
  # wrong in a way somebody can see, which beats a page that will not render.
  defp satisfied_names(scope) do
    %{nodes: nodes} = Requirements.project_graph(scope)

    for node <- nodes, node.satisfied, do: node.name
  rescue
    _ -> []
  end

  # The page that already answers for this step, rather than a health page built
  # for it. Every one of these exists.
  defp path_for("personas_complete", project), do: ~p"/app/projects/#{project.id}/personas"
  defp path_for("stories_exist", project), do: ~p"/app/projects/#{project.id}/stories"
  defp path_for("story_work", project), do: ~p"/app/projects/#{project.id}/stories"
  defp path_for("architecture_designed", project), do: ~p"/app/projects/#{project.id}/architecture"
  defp path_for("issues_triaged", project), do: ~p"/app/projects/#{project.id}/issues"
  defp path_for("issues_resolved", project), do: ~p"/app/projects/#{project.id}/issues"
  defp path_for("qa_" <> _, project), do: ~p"/app/projects/#{project.id}/qa"
  defp path_for(_name, project), do: ~p"/app/projects/#{project.id}/requirements"
end
