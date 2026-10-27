defmodule CodeMySpec.Analysis.Flakes do
  @moduledoc """
  Classifies a gate's test failures using retained project analysis history.

  A full run at the same commit that did not fail the test confirms a flake.
  Otherwise, failures in enough earlier unrelated candidates make it suspect.
  The caller supplies candidate evidence, including the files changed and
  covered by each candidate, because analysis runs do not record that mapping.
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
  @type classification :: %{
          failure: failure(),
          classification: :confirmed_flake | :suspected_flake | :failure,
          evidence: map()
        }

  @doc "Classify every failure in a gate, preserving input order and cardinality."
  @spec classify(Scope.t(), String.t(), [failure()], [candidate()]) :: [classification()]
  def classify(%Scope{} = scope, commit, failures, candidates \\ [])
      when is_binary(commit) and is_list(failures) and is_list(candidates) do
    history = History.list(scope)
    threshold = suspect_threshold()

    Enum.map(failures, fn failure ->
      classify_one(failure, commit, history, candidates, threshold)
    end)
  end

  @doc "Classify from already loaded history and candidate evidence."
  @spec classify_one(failure(), String.t(), [map()], [candidate()], pos_integer()) ::
          classification()
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

    case length(related) >= threshold do
      true ->
        %{failure: failure, classification: :suspected_flake, evidence: %{candidate_ids: related}}

      false ->
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
end
