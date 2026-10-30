defmodule CodeMySpec.Provisioning.Tools.DevopsStatus do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpec.Provisioning.Truncate
  alias CodeMySpec.Resources

  @impl true
  def name, do: "devops_status"

  @impl true
  def description do
    """
    Whether the infrastructure this account is supposed to have actually exists.

    Answers three separate questions, because conflating them is what made
    "is devops setup done?" unanswerable:

    - **missing** — a step whose resources are not there. This is what decides
      whether `devops_setup` is complete.
    - **dangling** — a resource that exists and points at nothing, usually a DNS
      record left over from a destroyed server. Not a completion problem; it is
      cleanup, and it does not block the requirement.
    - **unreachable** — a provider that could not be read. This is the absence of
      an answer, not a verdict. Do not treat it as "not done".

    Read from the providers, not from a record file. Setup completion used to be
    decided by grepping a markdown file for the words "verified" and "prod",
    which an agent could satisfy by writing prose.

    ## Never sees past the one project it is connected to

    `Resources.report/1` is deliberately account-wide — the cross-project
    dangling checks need to see everything, and that is right for `/app/
    resources`, a human looking at their own whole account. It is wrong for
    this tool: a caller reaching it through the harness is scoped to one
    project's work, and has no business learning what devops state, missing
    steps, or dangling resources some *other* project in the same account
    carries. Confirmed live, twice: first a project whose own devops was
    still `:off` got back a different project's checklist entirely; then,
    once devops was turned on, that *same* other project kept appearing in
    full detail beside the real answer, because the underlying call was still
    `Resources.report/1`. This uses `Resources.project_report/2` instead,
    which never runs `deployable/1` or asks a provider for anything beyond
    the one project it is given — there is no account-wide data left to leak,
    on or off.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope) do
      reply(scope, project)
    else
      {:error, reason} -> error(reason)
    end
  end

  defp reply(scope, project) do
    case Resources.project_report(scope, project) do
      {:ok, report} -> ok(summary(report, project))
      {:error, :devops_off} -> devops_off(project)
    end
  end

  defp devops_off(project) do
    {:error,
     "devops is off for #{project.name} — nothing to report. Turn it on for this " <>
       "project first; this tool never reports on any other project in the account."}
  end

  defp summary(report, project) do
    now = DateTime.utc_now()
    started_at = RunLock.in_flight(project.id)
    missing = Enum.filter(report.checklist, &(&1.state == :missing))
    dangling = Enum.filter(report.resources, &(&1.status == :dangling))

    [
      in_flight(started_at, report.checklist, now),
      headline(report, missing),
      steps(report.checklist, started_at, now),
      missing_section(missing),
      section("Dangling", dangling, &"#{&1.kind} #{&1.location}"),
      unreachable(report.errors)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # This tool's own docstring tells a caller who just started a run to "call
  # devops_status to watch it converge" — and until now nothing here ever
  # looked at whether one was still going. A caller re-checking this mid-run
  # got the checklist as it stood before the run started, indistinguishable
  # from a run that had already finished or one that had hung. `RunLock`
  # already tracks a run's `started_at`; this is the first thing to read it
  # (6f982579).
  #
  # To the second, not floored to minutes: an agent checked five times in 75s,
  # read "0 minutes ago" each time as a frozen clock, and escalated a normal
  # three-minute build as hung (82f09c49).
  defp in_flight(nil, _checklist, _now), do: ""

  defp in_flight(started_at, checklist, now) do
    "A setup run has been in progress since #{clock(started_at)} " <>
      "(#{age(started_at, now)} ago)#{running_on(checklist)}. The checklist " <>
      "below is read live, so it may show partial progress rather than a finished " <>
      "or a hung run — check again shortly rather than assuming either."
  end

  defp running_on(checklist) do
    case Enum.filter(checklist, &(&1[:step_state] == :running)) do
      [] -> ""
      running -> ", on " <> Enum.map_join(running, ", ", &step_label/1)
    end
  end

  defp headline(%{errors: errors}, _missing) when errors != %{},
    do:
      "Cannot say. One or more providers could not be read, so the answer is unknown rather than no."

  defp headline(_report, []), do: "Setup is complete: every step's resources are present."

  defp headline(_report, missing),
    do: "Setup is not complete: #{length(missing)} step(s) have nothing behind them."

  # Each step's last recorded state and its age, read at call time. Only the
  # error text used to show, so an old error read as fresh and an errored step
  # as "not converged yet" (82f09c49).
  defp steps([], _started_at, _now), do: ""

  defp steps(checklist, started_at, now) do
    ctx = %{
      now: now,
      run?: not is_nil(started_at),
      holder: Enum.find(checklist, &(&1[:step_state] == :paused))
    }

    "Steps (as of #{clock(now)}):\n" <>
      Enum.map_join(checklist, "\n", &("  - " <> step_line(&1, ctx)))
  end

  defp missing_section([]), do: ""

  defp missing_section(missing),
    do: "Missing (#{length(missing)}): " <> Enum.map_join(missing, ", ", &step_label/1)

  # The reason, when the step recorded one.
  #
  # The checklist has carried `detail` all along and this printed only the key,
  # so an agent asking what was missing got a list of names and no cause — and
  # then had to reproduce the run to learn what any of them said. One step
  # failing for a reason nobody could see cost three separate theories about
  # story 841 (provider capacity, an inventory bug, a placement fallback) before
  # anyone read the error the step had already stored.
  #
  # Truncated because a provider error can be a page of JSON, and the point here
  # is which step and why, not the whole body.
  #
  # Both ends, not the head and not just the tail either. Callers below this
  # (`Remote.install_kamal/1`, `Steps.with_output/2`) already learned that a
  # single-ended slice guesses which convention the failing tool follows —
  # apt/gem/SSHKit chatter buries its real cause at the end, but a Ruby `gem`
  # crash puts its own "ERROR: ..." line *before* the backtrace it raises.
  # This slice sits outside all of them, on top of whatever they already
  # composed, so it inherits the same problem one layer up: a head-only (or
  # tail-only) slice here can re-truncate an already-correct choice right
  # back off, discarding exactly what the inner fix kept. Confirmed live,
  # across the same incident, in both directions.
  #
  # `@doc false`: exists so the line is assertable without standing up a
  # real failing provider, the same reason `wrap_with_timeout/2` and
  # `image_tag/2` are public.
  @doc false
  def step_line(entry, ctx), do: step_label(entry) <> ": " <> phrase(entry, ctx) <> reason(entry)

  defp phrase(%{step_state: :running} = entry, %{run?: true} = ctx),
    do: "in progress, started #{ago(entry, ctx)}"

  defp phrase(%{step_state: :running} = entry, ctx),
    do: "interrupted — marked running #{ago(entry, ctx)} with no run active"

  # The sequence halts at its first paused step, so later ones are not
  # reached until it is resolved.
  defp phrase(%{step_state: :paused} = entry, %{holder: entry} = ctx),
    do: "paused #{ago(entry, ctx)}, holding the sequence"

  defp phrase(%{step_state: state} = entry, ctx) when state in [:done, :errored, :paused],
    do: "#{state} #{ago(entry, ctx)}"

  defp phrase(_entry, _ctx), do: "not started"

  defp ago(%{recorded_at: %DateTime{} = at}, %{now: now}), do: "#{age(at, now)} ago"
  defp ago(_entry, _ctx), do: "at an unrecorded time"

  defp reason(%{key: key, step_state: :errored, detail: "Deploy refused at " <> _ = text})
       when key in [:deploy, "deploy"],
       do: " — " <> text

  defp reason(%{step_state: :errored, detail: text}) when is_binary(text) and text != "",
    do: " — " <> Truncate.head_and_tail(text)

  defp reason(%{step_state: :paused, paused_instructions: text})
       when is_binary(text) and text != "",
       do: " — " <> Truncate.head_and_tail(text)

  defp reason(_entry), do: ""

  # Seconds while a wait is short enough to watch, coarser once it is not.
  defp age(at, now) do
    case max(DateTime.diff(now, at, :second), 0) do
      s when s < 60 -> "#{s}s"
      s when s < 600 -> "#{div(s, 60)}m #{rem(s, 60)}s"
      s when s < 3600 -> "#{div(s, 60)}m"
      s when s < 86_400 -> "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
      s -> "#{div(s, 86_400)}d #{div(rem(s, 86_400), 3600)}h"
    end
  end

  defp clock(at), do: "#{at |> DateTime.truncate(:second) |> DateTime.to_time()}Z"

  # A per-environment step has one row per environment, so without the
  # environment `uat` and `prod` rows read as duplicates (548b3173).
  defp step_label(%{environment: env} = entry) when is_binary(env),
    do: "#{entry.project_name}/#{env}/#{entry.key}"

  defp step_label(entry), do: "#{entry.project_name}/#{entry.key}"

  defp section(_label, [], _fmt), do: ""

  defp section(label, entries, fmt),
    do: "#{label} (#{length(entries)}):\n" <> Enum.map_join(entries, "\n", &("  - " <> fmt.(&1)))

  defp unreachable(errors) when errors == %{}, do: ""

  defp unreachable(errors) do
    "Unreachable (#{map_size(errors)}):\n" <>
      Enum.map_join(errors, "\n", fn {provider, reason} ->
        "  - #{provider}: #{inspect(reason)}"
      end)
  end

  defp ok(summary), do: {:ok, summary}

  defp error(reason),
    do: {:error, "Could not read devops status: #{inspect(reason)}"}
end
