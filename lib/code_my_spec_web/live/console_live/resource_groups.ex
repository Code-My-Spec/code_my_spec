defmodule CodeMySpecWeb.ConsoleLive.ResourceGroups do
  @moduledoc """
  The console's Resources grouping — servers, DNS and domain, mail in and
  out, storage and backups, publishing, feedback widget — each combining
  the step keys that make it up, so Resources shows six-ish cards instead
  of `Sequence`'s fourteen separate steps.

  Repository, secrets (the age-key step, not the Secrets section), the
  callback credential and monitoring aren't named in the plan's own list.
  Dropping them would make their state unreachable from the console at
  all, so they're folded in here rather than left out: repository gets its
  own card (nothing else fits it), and secrets/callback_credential/
  monitoring join servers, since all three are server-and-app-runtime
  concerns. This is an interpretation, not a spec — worth confirming with
  whoever reviews the layout.
  """

  @groups [
    %{key: :repository, label: "Repository", step_keys: [:repository]},
    %{
      key: :servers,
      label: "Servers",
      step_keys: [:server, :secrets, :callback_credential, :monitoring]
    },
    %{key: :dns_domain, label: "DNS and domain", step_keys: [:domain, :dns, :tls]},
    %{key: :mail, label: "Mail in and out", step_keys: [:email, :inbound]},
    %{key: :storage_backups, label: "Storage and backups", step_keys: [:storage, :backups]},
    %{key: :publishing, label: "Publishing", step_keys: [:content]},
    %{key: :widget, label: "Feedback widget", step_keys: [:widget]},
    %{key: :telemetry, label: "Telemetry", step_keys: [:telemetry]}
  ]

  @doc "Every group, in display order."
  def all, do: @groups

  @doc "One group by its key, or nil."
  def get(key), do: Enum.find(@groups, &(&1.key == key))

  @doc """
  Which group's tab a step's own activity belongs under, as a string —
  `deploy` has no group (it's `Deploys`' own page), so it answers for
  itself rather than through a lookup that would otherwise return nil.
  """
  def for_step(:deploy), do: "deploys"

  def for_step(key) do
    @groups
    |> Enum.find(&(key in &1.step_keys))
    |> case do
      %{key: group_key} -> to_string(group_key)
      nil -> to_string(key)
    end
  end

  @doc """
  A group's own steps from the plan, scoped to one environment — a
  per-environment step (dns, tls, server, ...) shows only that
  environment's row, same as `ConsoleLive.environment_scoped/2` does for a
  single step.
  """
  def steps(plan, group, environment) do
    for step <- plan,
        step.key in group.step_keys,
        is_nil(step.environment) or step.environment == environment,
        do: step
  end

  @doc """
  A group's status, for its card — the worst state among its steps, in the
  order a run would actually halt: errored beats paused beats running beats
  not_started, and only every step done makes the group done.
  """
  def status(steps) do
    cond do
      steps == [] -> :not_started
      Enum.any?(steps, &(&1.state == :errored)) -> :errored
      Enum.any?(steps, &(&1.state == :paused)) -> :paused
      Enum.any?(steps, &(&1.state == :running)) -> :running
      Enum.all?(steps, &(&1.state == :done)) -> :done
      true -> :not_started
    end
  end
end
