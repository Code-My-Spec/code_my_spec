defmodule CodeMySpec.Analysis.Flakes do
  @moduledoc """
  Classifies a gate's test failures using retained project analysis history.

  A full run at the same commit that did not fail the test confirms a flake.
  Otherwise, failures in enough earlier unrelated candidates make it suspect.
  The caller supplies candidate evidence, including the files changed and
  covered by each candidate, because analysis runs do not record that mapping.
  Also supports exunit history classification for promotion logging.
  """

  alias CodeMySpec.Analysis.History
  alias CodeMySpec.Users.Scope

  @default_suspect_threshold 3

  @type failure ::
          %{required(:file) => String.t(), required(:name) => String.t()}
          | %{required(String.t()) => String.t()}
  @type candidate :: %{
          required(:id) => String.t(),
          required(:failures) => [failure()],
          required(:changed_files) => [String.t()],
          required(:covered_files) => [String.t()]
        }
  @type gate_classification :: %{
          failure: failure(),
          classification: :confirmed_flake | :suspected_flake | :failure,
          evidence: map()
        }

  @doc "Classify every failure in a gate, preserving input order and cardinality."
  @spec classify_gate(Scope.t(), String.t(), [failure()], [candidate()]) :: [
          gate_classification()
        ]
  def classify_gate(%Scope{} = scope, commit, failures, candidates \\ [])
      when is_binary(commit) and is_list(failures) and is_list(candidates) do
    history = History.list(scope)
    threshold = suspect_threshold()

    Enum.map(failures, fn failure ->
      classify_one(failure, commit, history, candidates, threshold)
    end)
  end

  @doc "Classify from already loaded history and candidate evidence."
  @spec classify_one(failure(), String.t(), [map()], [candidate()], pos_integer()) ::
          gate_classification()
  def classify_one(failure, commit, history, candidates, threshold \\ @default_suspect_threshold)
      when is_map(failure) and is_binary(commit) and is_list(history) and
             is_list(candidates) and is_integer(threshold) and threshold > 0 do
    identity = identity(failure)

    case passing_run(history, commit, identity) do
      nil ->
        suspect_or_failure(failure, identity, candidates, threshold)

      run ->
        %{
          failure: failure,
          classification: :confirmed_flake,
          evidence: %{run_id: run.run_id, commit: commit}
        }
    end
  end

  defp passing_run(history, commit, {file, _name} = key) do
    source = source_for(file)

    Enum.find(history, fn run ->
      run.commit == commit and run.source == source and
        run.status == :completed and run.partial == false and
        not Enum.any?(run.failures, &(identity(&1) == key))
    end)
  end

  defp source_for("test/spex/" <> _rest), do: "spex"
  defp source_for(_file), do: "exunit"

  defp suspect_or_failure(failure, identity, candidates, threshold) do
    related =
      candidates
      |> Enum.filter(&unrelated_failure?(&1, identity))
      |> Enum.map(& &1.id)
      |> Enum.uniq()

    if length(related) >= threshold do
      %{failure: failure, classification: :suspected_flake, evidence: %{candidate_ids: related}}
    else
      %{failure: failure, classification: :failure, evidence: %{}}
    end
  end

  defp unrelated_failure?(candidate, {file, _name} = identity) do
    Enum.any?(candidate.failures, &(identity(&1) == identity)) and
      not Enum.member?(candidate.changed_files, file) and
      Enum.all?(candidate.changed_files, &(&1 not in candidate.covered_files))
  end

  defp identity(%{file: file, name: name}) when is_binary(file) and is_binary(name),
    do: {file, name}

  defp identity(%{"file" => file, "name" => name})
       when is_binary(file) and is_binary(name),
       do: {file, name}

  defp suspect_threshold do
    case Application.get_env(:code_my_spec, :flake_suspect_threshold, @default_suspect_threshold) do
      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError, "flake_suspect_threshold must be positive, got: #{inspect(value)}"
    end
  end

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

  defp same_commit_pass?(run, commit, file, name) do
    run.status == :completed and run.findings_recorded and run.completed_commit == commit and
      not run.partial and not failed?(run, file, name)
  end

  defp prior_failure?(run, commit, file, name) do
    run.status == :completed and run.findings_recorded and run.commit != commit and
      not run.partial and not is_nil(run.working_copy_id) and failed?(run, file, name)
  end

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
