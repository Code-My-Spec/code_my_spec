defmodule CodeMySpec.Requirements.QaIntegrationPlanChecker do
  @moduledoc """
  The `qa_integration_plan` requirement's check: the integration index exists,
  and every integration spec names a verify script that is on disk and is
  marked verified.

  A check over File rows the graph has already loaded, so it lives with the
  graph. It used to be `AgentTasks.QaIntegrationPlan.evaluate/3`, which made the
  graph call up into the task layer to compute one of its own verdicts;
  `QaIntegrationPlan` delegates here now.
  """

  alias CodeMySpec.{Files, Paths}

  @integrations_index Paths.integrations_index()
  @integrations_dir Paths.integrations_dir()

  @doc """
  Validate integration planning output.

  State machine:
  1. Integration index exists?
  2. All expected integration specs exist?
  3. All specs have verify scripts?
  4. All specs have `status: verified`?

  Answered from the File rows alone — no disk, no environment, no harness.

  This is a delegate on the **project** template, so it runs for every project
  on every graph computation, and `next_actionable/1` computes the graph on
  every cache miss. It used to glob for the spec list and read each spec for its
  status and verify-script path. Against a harness-served project every one of
  those is a `GenServer.call` to the harness with a 35-second limit; measured, a
  stop decision that waited 35s on the glob and 24 more on a read, then answered
  nothing. Locally they are fast file reads, which is why this only ever bit the
  light harness — the deployment that by design has no disk to read.

  Everything it asks is already a row. `Scanner.classify/1` claims the
  integrations directory and the QA scripts directory, so the specs and the
  scripts they name both sync; `validate_integration/1` parses each spec's
  status and script path at sync time, where the file is, and carries the answer
  in `validation_errors`. The presence of the index is `size` on its row.

  So the question moved rather than the parsing: "is this integration verified"
  is decided once when the file changes instead of on every stop hook, and the
  requirement reads a verdict.
  """
  def evaluate(scope, task), do: evaluate(scope, task, nil)

  # The graph hands `ctx` to any delegate exporting arity 3
  # (`RequirementCalculator.delegate_args/5`), and `files_by_project` is every
  # File row it already loaded — so on the path that runs per computation this
  # costs no query at all.
  def evaluate(scope, _task, ctx) do
    rows = integration_files(ctx, scope)
    specs = Enum.filter(rows, &spec_file?(&1.path))

    if specs == [] do
      {:ok, :valid}
    else
      with :ok <- check_index(rows),
           :ok <- check_verify_scripts(rows, specs),
           :ok <- check_verified_status(specs) do
        {:ok, :valid}
      else
        {:error, feedback} ->
          {:ok, :invalid, feedback}
      end
    end
  end

  # `size` is what "empty" meant when this read the file — the same distinction
  # between written and started, from the row the sync already keeps.
  # A project can legitimately have no rows at all — nothing synced yet — and
  # the caller has already established that it has specs, so a missing index is
  # a real gap rather than an unobservable one.
  defp check_index(rows) do
    case Enum.find(rows, &(&1.path == @integrations_index)) do
      %{size: size} when is_integer(size) and size > 0 ->
        :ok

      %{} ->
        {:error, "Integration index is empty. Write `#{@integrations_index}` and stop again."}

      nil ->
        {:error,
         "Integration index not found at `#{@integrations_index}`. Write it and stop again."}
    end
  end

  # Every row the graph loaded, or every row in the project. Filtered by path
  # rather than queried by role, because the ctx list is not narrowed by role
  # and one predicate for both callers is what keeps them agreeing.
  defp integration_files(%{files_by_project: files}, _scope) when is_list(files), do: files
  defp integration_files(_ctx, scope), do: Files.list_project_files(scope)

  # `*.md` directly under the integrations directory, which is what the glob
  # matched: `Path.dirname/1` on a nested path answers the subdirectory, so a
  # spec's supporting files do not read as specs. The index sits beside the
  # directory rather than in it and is excluded by the same rule.
  defp spec_file?(path),
    do: Path.dirname(path) == @integrations_dir and Path.extname(path) == ".md"

  # The script a spec names has a row of its own — `Scanner.classify/1` claims
  # anything under the QA scripts directory — so "is it there" is a lookup.
  defp check_verify_scripts(rows, specs) do
    paths = MapSet.new(rows, & &1.path)
    Enum.reduce_while(specs, :ok, fn spec, :ok -> check_verify_script(spec, paths) end)
  end

  defp check_verify_script(spec, paths) do
    case data(spec, "verify_script") do
      nil ->
        {:halt,
         {:error,
          "Integration spec `#{spec.path}` has no verify script path. " <>
            "Add a `## Verify Script` section."}}

      script ->
        if MapSet.member?(paths, script) do
          {:cont, :ok}
        else
          {:halt,
           {:error,
            "Verify script `#{script}` missing (referenced by `#{spec.path}`). " <>
              "Create it and stop again."}}
        end
    end
  end

  defp check_verified_status(specs) do
    Enum.reduce_while(specs, :ok, fn spec, :ok ->
      if data(spec, "verified") == true do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          "Integration `#{spec.path}` is not yet verified. Run the verify script and set " <>
            "`## Status` to `verified`."}}
      end
    end)
  end

  # `validation_errors` round-trips through a `:map` column, so the keys come
  # back as strings whatever they went in as. A row written before this
  # validator existed has no `data` at all, and reads as "not verified" and "no
  # script" — which is what it is until the next scan touches the file.
  defp data(%{validation_errors: %{"data" => data}}, key) when is_map(data),
    do: Map.get(data, key)

  defp data(_row, _key), do: nil
end
