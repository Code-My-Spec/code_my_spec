defmodule CodeMySpec.Workspaces.BootSteps do
  @moduledoc """
  The phases an instance goes through, and how to tell which one it is in.

  The devbox entrypoint announces each phase on stdout, so progress is read
  from what the container actually reports rather than guessed from elapsed
  time. A bar driven by a timer lies exactly when the boot is in trouble,
  which is the moment it matters.

  Pure — the log text comes from the runner.
  """

  @steps [
    %{key: :starting_database, marker: "Starting Postgres", label: "Starting the database"},
    %{key: :generating, marker: "with mix cms.new", label: "Generating your application"},
    %{key: :reusing, marker: "Reusing existing project", label: "Reusing your application"},
    %{key: :fetching_deps, marker: "Fetching dependencies", label: "Fetching dependencies"},
    %{key: :migrating, marker: "Setting up the database", label: "Setting up the database"},
    %{key: :starting_harness, marker: "Starting the cms harness", label: "Starting the harness"},
    # The app's own line is the only one carrying its port; a bare "Starting"
    # also matches Postgres and the harness and would jump the bar to done.
    %{key: :starting_app, marker: "on :4000", label: "Starting your application"}
  ]

  # `generating` and `reusing` are alternatives on the same rung, so a reused
  # workspace doesn't read as though it skipped a phase.
  @positions %{
    starting_database: 1,
    generating: 2,
    reusing: 2,
    fetching_deps: 3,
    migrating: 4,
    starting_harness: 5,
    starting_app: 6
  }

  @total 6

  @type step ::
          :starting_database
          | :generating
          | :reusing
          | :fetching_deps
          | :migrating
          | :starting_harness
          | :starting_app

  @spec steps() :: [map()]
  def steps, do: @steps

  @spec total() :: pos_integer()
  def total, do: @total

  @doc "How far along a step is, 1-based. `nil` has not started."
  @spec position(step() | nil) :: non_neg_integer()
  def position(nil), do: 0
  def position(step), do: Map.fetch!(@positions, step)

  @doc "Percent complete, for a bar. A running workspace is done regardless of the last marker."
  @spec percent(step() | nil) :: non_neg_integer()
  def percent(step), do: round(position(step) / @total * 100)

  @doc "What to show the visitor."
  @spec label(step() | nil) :: String.t()
  def label(nil), do: "Getting ready"

  def label(step) do
    Enum.find_value(@steps, "Working", fn
      %{key: ^step, label: label} -> label
      _ -> nil
    end)
  end

  @doc """
  The furthest phase the log shows, or nil if none has been announced.

  Furthest rather than last-matched, so out-of-order or interleaved output
  never walks the bar backwards.
  """
  @spec furthest(String.t()) :: step() | nil
  def furthest(log) when is_binary(log) do
    @steps
    |> Enum.filter(&announced?(log, &1))
    |> Enum.max_by(&position(&1.key), fn -> nil end)
    |> step_key()
  end

  defp step_key(nil), do: nil
  defp step_key(%{key: key}), do: key

  # Only lines the entrypoint announced count — the marker text appears in
  # ordinary build output too, and matching that would race the bar ahead.
  defp announced?(log, %{marker: marker}) do
    log
    |> String.split("\n")
    |> Enum.any?(&(String.contains?(&1, "==>") and String.contains?(&1, marker)))
  end
end
