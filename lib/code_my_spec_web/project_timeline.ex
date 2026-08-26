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
      <%!-- Five phases and thirteen steps have to be legible at 390px without
      scrolling, and the thing that did not fit was the words. Every phase used
      to print its name, so `BUILDING`, `CHECKING` and `PROVING` fell off the
      right-hand edge of a phone with no scrollbar to say they were there — a
      strip that looks complete and does not contain your own phase.

      So the names go and the shapes stay. A phase is a pie: how much of it is
      done, readable without reading. Its steps stay as dots beside it, because
      the whole graph on the line is the point — a cut list cannot answer a
      question about a step it left out. Only the phase you are in keeps its
      name, and the step you are on is named once, underneath. --%>
      <%!-- One colour language, used by pies and dots alike: green is done,
      primary is where you are, grey is not yet. Before this, done and not-yet
      were both grey and only the current step had colour, so a finished phase
      and an untouched one looked identical — the pie was full and said nothing
      about it. --%>
      <ol class="flex flex-wrap items-center gap-x-4 gap-y-1">
        <li
          :for={phase <- @steps}
          data-test="timeline-phase"
          data-phase={phase.key}
          data-expanded={to_string(phase.expanded?)}
          class={
            [
              "flex shrink-0 items-center gap-1.5",
              # Bounded, so the name belongs to a group rather than floating
              # between two of them. Without it "DESIGN" sits between one pie and
              # another and labels neither.
              phase.expanded? &&
                "rounded-full bg-base-100 px-2 py-0.5 text-primary ring-1 ring-primary/30",
              not phase.expanded? && phase_complete?(phase) && "text-success",
              not phase.expanded? && not phase_complete?(phase) && "text-base-content/30"
            ]
          }
        >
          <%!-- The pie is the phase's visible mark and its way in. Hovering
          names it and says how far through it is, which is what the phase name
          used to cost a line of text to say. --%>
          <.link
            navigate={phase_path(phase)}
            title={"#{phase.label} — #{phase_done(phase)} of #{length(phase.steps)} done"}
            class="flex shrink-0 items-center gap-1"
          >
            <span
              data-test="phase-pie"
              data-done={phase_done(phase)}
              data-total={length(phase.steps)}
              style={pie_style(phase)}
              class={[
                "size-4 shrink-0 rounded-full ring-1",
                phase.expanded? && "ring-primary",
                not phase.expanded? && phase_complete?(phase) && "ring-success/60",
                not phase.expanded? && not phase_complete?(phase) && "ring-base-content/25"
              ]}
            >
            </span>

            <span :if={phase.expanded?} class="text-xs font-semibold uppercase tracking-wide">
              {phase.label}
            </span>

            <span class="sr-only">{phase.label}</span>
          </.link>

          <%!-- Dots are drawn only for the phase you are in. A collapsed phase
          is its pie, which already carries how many steps it holds and how many
          are done — aggregating, not cutting, which is why a pie can still
          answer a question about a step while a shortened list cannot.

          Every step keeps its link either way. Drawing nothing is a visual
          decision and must not become an unreachable one: a step outside the
          current phase is still a way in rather than a dead end, still named,
          and still keyboard-reachable. What changes is whether it takes space. --%>
          <span
            :for={step <- phase.steps}
            data-test="timeline-step"
            data-step={step.name}
            data-state={step.state}
          >
            <.link
              navigate={step.path}
              title={step.title}
              class={[phase.expanded? && "block px-0.5 py-1", not phase.expanded? && "sr-only"]}
            >
              <span
                :if={phase.expanded?}
                class={[
                  "block size-2 rounded-full",
                  step.state == "current" && "bg-primary ring-2 ring-primary/40",
                  step.state == "done" && "bg-success",
                  step.state == "todo" && "bg-base-content/20"
                ]}
              >
              </span>
              <span class="sr-only">{step.title}</span>
            </.link>
          </span>
        </li>
      </ol>

      <%!-- The step you are on, and nothing about it. The two explanatory
      sentences that used to sit here were the bulk of the header on every
      screen, and the header exists to be glanced at. John: "remove on both".
      Criterion 2927, which held those sentences to plain language, is retired
      with them — there is no longer any prose for it to govern. --%>
      <p :if={current_title(@steps)} data-test="step-title" class="mt-1 text-sm font-semibold">
        {current_title(@steps)}
      </p>
    </nav>
    """
  end

  # The step you are on, named once. It used to be named by being the only
  # step whose title was printed in the strip, which cost five phase names and
  # thirteen step titles across the top to say one thing.
  defp current_title(phases) do
    phases
    |> Enum.flat_map(& &1.steps)
    |> Enum.find_value(fn step -> step.state == "current" && step.title end)
  end

  defp phase_done(phase), do: Enum.count(phase.steps, &(&1.state == "done"))

  defp phase_complete?(phase),
    do: phase.steps != [] and phase_done(phase) == length(phase.steps)

  # Where clicking a phase goes: the step it is on, or its first if it has not
  # started. A pie that names a phase on hover and does nothing on click is an
  # affordance that lies.
  defp phase_path(phase) do
    current = Enum.find(phase.steps, &(&1.state == "current"))
    (current || hd(phase.steps)).path
  end

  # A phase as a wedge. `currentColor` so the pie takes the phase's own colour —
  # primary for the one you are in, muted for the rest — and the ring around it
  # draws the whole, so an empty phase still reads as a phase rather than as
  # nothing.
  defp pie_style(phase) do
    total = length(phase.steps)
    done = phase_done(phase)
    pct = if total == 0, do: 0, else: round(done / total * 100)

    "background: conic-gradient(currentColor #{pct}%, transparent 0)"
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

  defp path_for("architecture_designed", project),
    do: ~p"/app/projects/#{project.id}/architecture"

  defp path_for("issues_triaged", project), do: ~p"/app/projects/#{project.id}/issues"
  defp path_for("issues_resolved", project), do: ~p"/app/projects/#{project.id}/issues"
  defp path_for("qa_" <> _, project), do: ~p"/app/projects/#{project.id}/qa"
  defp path_for(_name, project), do: ~p"/app/projects/#{project.id}/requirements"
end
