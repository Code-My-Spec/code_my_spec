defmodule CodeMySpecSpex.EvalArtifacts do
  @moduledoc """
  Reading what `mix cms.eval` recorded, for spex that assert on it.

  These spex never start an agent and never call a model. They read the
  artifacts under `test/fixtures/evals/` and answer two questions in order:

  1. Is this artifact still about the prompt we ship today? If not it is not
     evidence, and the criterion fails as **stale** rather than as a rate.
  2. Does the rate meet the criterion's threshold?

  The order matters and so does keeping the two failures apart. Both are red,
  but one says the agent is wrong and the other says nobody has measured it
  yet — and sending somebody to debug an agent that was never measured is the
  expensive mistake.

  ## Why staleness fails rather than warns

  An artifact recorded against one prompt says nothing about a different one. A
  green built on one is a latch: it stays green because nothing re-ran, which
  is the failure mode the artifact split exists to avoid. Failing means a prompt
  edit red-lights its criteria until somebody re-records, which is the intended
  pressure.

  ## Similarity, not identity

  Hashing the prompt would make every whitespace reflow and every tool-list
  reordering a failure, which trains people to ignore the signal. So this
  compares normalised text and allows a little drift.

  Two things are normalised out first, or the threshold fights noise instead of
  measuring drift:

  - **Machine-specific tool names.** The tool index carries the browser's tools
    on a box that has a browser and none on a box that does not, so the index is
    compared as a *set of names* rather than as a line of text.
  - **Whitespace**, which carries no meaning here.

  ### The known weakness

  Text similarity does not track significance, and the counterexample is the
  criterion this was built for. 3539 asserts an agent claims work before doing
  it, and the instruction that makes it true is one line in a prompt of some ten
  thousand characters. Delete that line and the prompt is 99.9% the same —
  inside any threshold — while the behaviour is no longer supported by the
  prompt at all.

  So the percentage is a pragmatic filter against churn, not a correctness
  argument. If it starts lying in either direction the fix is to compare
  structure rather than characters: diff at the instruction level and treat an
  added, removed or reworded instruction as drift. Written down so that when
  somebody hits it, it reads as a known limit rather than a surprise.
  """

  alias CodeMySpec.Agents.{OperatingRules, ProviderBrief, RoleBrief}

  @root "test/fixtures/evals"

  # Below this, the prompt has moved and the artifact is not evidence.
  @similar_enough 0.95

  @doc """
  Every recorded run for a criterion, oldest first.

  Raises when there are none: a criterion with no artifacts has not been
  measured, and answering `[]` would let a rate of "0 of 0" read as a pass.
  """
  @spec runs(String.t()) :: [map()]
  def runs(criterion) do
    dir = Path.join(@root, criterion)

    case File.ls(dir) do
      {:ok, []} -> raise no_artifacts(criterion, dir)
      {:error, :enoent} -> raise no_artifacts(criterion, dir)
      {:ok, files} -> files |> Enum.sort_by(&run_number/1) |> Enum.map(&read(dir, &1))
    end
  end

  @doc """
  The measured runs, which is every run that did not error.

  An errored run is not evidence about the agent — a premise that did not hold,
  a fixture that collided — so it is not in the denominator.
  """
  @spec measured([map()]) :: [map()]
  def measured(runs), do: Enum.reject(runs, & &1["errored"])

  @doc "How often the agent did the right thing, as `{held, measured}`."
  @spec rate([map()]) :: {non_neg_integer(), non_neg_integer()}
  def rate(runs) do
    taken = measured(runs)
    {Enum.count(taken, & &1["held?"]), length(taken)}
  end

  @doc """
  The prompt these runs were measured against, or `nil` for an older artifact.

  One prompt for the whole set: every run of a criterion launches the same role
  against the same sections, so a set whose runs disagree is a set recorded
  across an edit and is reported as stale by `assert_current!/2`.
  """
  @spec recorded_prompt([map()]) :: map() | nil
  def recorded_prompt(runs) do
    runs
    |> Enum.map(& &1["prompt"])
    |> Enum.find(&is_map/1)
  end

  @doc """
  These runs in the shape `AgentEvalHelpers.assert_rate/2` reads.

  Reusing that assertion rather than growing a second one: it already says the
  right thing about a rate in the middle — that it is the finding and not a
  flake — and two places that phrase a verdict is one that drifts.

  `misses` carries what the agent actually did, so a red run names the evidence
  instead of sending somebody to open ten JSON files.
  """
  @spec result([map()], String.t()) :: map()
  def result(runs, behaviour) do
    taken = measured(runs)
    {hits, total} = rate(runs)

    %{
      behaviour: behaviour,
      runs: total,
      hits: hits,
      rate: if(total > 0, do: hits / total, else: 0.0),
      errored: length(runs) - total,
      misses: misses_of(taken)
    }
  end

  defp misses_of(taken) do
    for run <- taken, not run["held?"], do: {run["run"], run["held?"], evidence(run)}
  end

  # What it called, and the last thing it said. Between them those answer the
  # first question anybody asks of a miss — whether it did the wrong thing or
  # never got started.
  defp evidence(run) do
    called =
      case run["calls"] do
        [] -> "called nothing"
        calls -> Enum.join(calls, " ")
      end

    case last_message(run) do
      nil -> called
      said -> "#{called} — #{said}"
    end
  end

  defp last_message(run) do
    (run["trace"] || [])
    |> Enum.filter(&(&1["event"] == "message"))
    |> List.last()
    |> case do
      nil -> nil
      event -> event |> Map.get("detail", "") |> String.slice(0, 220)
    end
  end

  @doc """
  Fail unless these artifacts were recorded against the prompt we ship today.

  `role` is the criterion's role, because `RoleBrief.for/1` is the one section
  that differs between two criteria measured on the same machine.
  """
  @spec assert_current!([map()], String.t()) :: :ok
  def assert_current!(runs, role) do
    case recorded_prompt(runs) do
      nil ->
        raise """
        These artifacts predate prompt recording, so nothing can say whether
        they describe the prompt we ship today.

        Re-record: MIX_ENV=test mix cms.eval
        """

      recorded ->
        compare(recorded, current(role))
    end
  end

  defp compare(recorded, current) do
    drifted =
      for {section, now} <- current,
          was = Map.get(recorded, section),
          similarity(normalise(section, was), normalise(section, now)) < @similar_enough,
          do: {section, similarity(normalise(section, was), normalise(section, now))}

    if drifted == [] do
      :ok
    else
      raise """
      STALE — these artifacts were recorded against a different prompt, so they
      are not evidence about the one we ship. This is not a statement about the
      agent: it has not been measured against today's prompt.

      Sections that moved:
      #{Enum.map_join(drifted, "\n", fn {section, score} -> "  #{section}: #{round(score * 100)}% of the recorded text" end)}

      Re-record: MIX_ENV=test mix cms.eval
      """
    end
  end

  # What the server would send an agent of this role on this machine, in the
  # same shape the artifact holds. `project_brief` and `app_url` are left out:
  # both are per-project columns rather than the prompt we ship, and an eval
  # world has neither.
  defp current(role) do
    %{
      "universal" => OperatingRules.text(),
      "role_brief" => RoleBrief.for(role),
      "provider_brief" => ProviderBrief.for("claude-code")
    }
  end

  # The tool index is a list of names, and which names a machine has depends on
  # the machine — the browser's tools are there on a box with a browser and
  # absent on one without. Comparing it as text stales every artifact on every
  # other box, so it is compared as a sorted set when it is compared at all.
  defp normalise("tool_index", nil), do: ""

  defp normalise("tool_index", text) do
    text
    |> String.split(~r/[,\s]+/, trim: true)
    |> Enum.sort()
    |> Enum.join(" ")
  end

  defp normalise(_section, nil), do: ""
  defp normalise(_section, text), do: text |> String.split() |> Enum.join(" ")

  # Token overlap rather than an edit distance: cheap, stable under reflowing,
  # and it moves when words are added or removed, which is the drift worth
  # catching.
  defp similarity("", ""), do: 1.0
  defp similarity("", _), do: 0.0
  defp similarity(_, ""), do: 0.0

  defp similarity(a, b) do
    was = a |> String.split() |> MapSet.new()
    now = b |> String.split() |> MapSet.new()
    shared = MapSet.intersection(was, now) |> MapSet.size()

    shared / MapSet.size(MapSet.union(was, now))
  end

  defp read(dir, file), do: dir |> Path.join(file) |> File.read!() |> Jason.decode!()

  defp run_number(file), do: file |> Path.rootname() |> String.to_integer()

  defp no_artifacts(criterion, dir) do
    """
    No artifacts for #{criterion} in #{dir}, so it has not been measured.

    A criterion with nothing recorded is not a passing criterion — record it:

        MIX_ENV=test mix cms.eval --pattern #{criterion}
    """
  end
end
