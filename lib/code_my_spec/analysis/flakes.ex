defmodule CodeMySpec.Analysis.Flakes do
  @moduledoc """
  Classifies an exunit gate failure using retained project analysis history.

  A full same-commit pass confirms a flake. Earlier unrelated candidate
  failures can make it suspect; the caller supplies `:unrelated_candidate?`
  because analysis history does not record which code a test covers.
  """

  alias CodeMySpec.Analysis.History
  alias CodeMySpec.Users.Scope

  @default_suspect_threshold 3

  @type classification :: :confirmed_flake | :suspected_flake | :no_flake_evidence
  @type result :: %{classification: classification(), failure: map(), evidence: [map()]}

  @doc "Classify every failure independently, retaining its evidence."
  @spec classify_all(Scope.t(), String.t(), [map()], keyword()) :: [result()]
  def classify_all(%Scope{} = scope, commit, failures, opts \\ [])
      when is_binary(commit) and is_list(failures) and is_list(opts) do
    runs = History.list(scope, source: "exunit")
    Enum.map(failures, &classify_from_runs(&1, commit, runs, opts))
  end

  @doc "Classify one failure using the same evidence rules as `classify_all/4`."
  @spec classify(Scope.t(), String.t(), map(), keyword()) :: result()
  def classify(%Scope{} = scope, commit, failure, opts \\ [])
      when is_binary(commit) and is_map(failure) and is_list(opts) do
    scope
    |> classify_all(commit, [failure], opts)
    |> hd()
  end

  defp classify_from_runs(failure, commit, runs, opts) when is_map(failure) do
    {file, name} = identity!(failure)

    case Enum.find(runs, &same_commit_pass?(&1, commit, file, name)) do
      nil -> suspect_or_failure(failure, commit, runs, opts, file, name)
      run -> %{classification: :confirmed_flake, failure: failure, evidence: [run]}
    end
  end

  defp suspect_or_failure(failure, commit, runs, opts, file, name) do
    threshold =
      Keyword.get(
        opts,
        :suspect_threshold,
        Application.get_env(:code_my_spec, :flake_suspect_threshold, @default_suspect_threshold)
      )

    unrelated? = Keyword.get(opts, :unrelated_candidate?, fn _run, _failure -> false end)

    unless is_integer(threshold) and threshold > 0 do
      raise ArgumentError, "suspect_threshold must be a positive integer"
    end

    unless is_function(unrelated?, 2) do
      raise ArgumentError, "unrelated_candidate? must be a function of arity 2"
    end

    candidates =
      runs
      |> Enum.filter(&(prior_failure?(&1, commit, file, name) and unrelated?.(&1, failure)))
      |> Enum.uniq_by(& &1.working_copy_id)

    if length(candidates) >= threshold do
      %{classification: :suspected_flake, failure: failure, evidence: candidates}
    else
      %{classification: :no_flake_evidence, failure: failure, evidence: []}
    end
  end

  # Evidence is a run of the code at its commit: a run that started on a dirty
  # tree tested uncommitted work, and an agent's half-written test read as a
  # confirmed flake.
  defp same_commit_pass?(run, commit, file, name) do
    evidence?(run) and run.completed_commit == commit and not failed?(run, file, name)
  end

  defp prior_failure?(run, commit, file, name) do
    evidence?(run) and run.commit != commit and not is_nil(run.working_copy_id) and
      failed?(run, file, name)
  end

  defp evidence?(run),
    do: run.status == :completed and run.findings_recorded and not run.partial and run.clean

  defp failed?(run, file, name) do
    Enum.any?(run.failures, fn failure ->
      value(failure, :file) == file and value(failure, :name) == name
    end)
  end

  defp identity!(failure) do
    case {value(failure, :file), value(failure, :name)} do
      {file, name} when is_binary(file) and is_binary(name) -> {file, name}
      other -> raise ArgumentError, "failure needs file and name, got: #{inspect(other)}"
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
