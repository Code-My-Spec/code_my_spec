defmodule CodeMySpec.AgentTasks.QaIntegrationPlan do
  @moduledoc """
  Identify third-party integrations from ADRs and verify each against real credentials.

  See spec: `.code_my_spec/spec/code_my_spec/agent_tasks/qa_integration_plan.spec.md`.
  """

  def dispatch(_node) do
    "Identify third-party integrations from technical decisions, draft a " <>
      "spec + verify script per integration, gather credentials from the " <>
      "engineer, and run verify until each spec is `status: verified`. " <>
      "Use when ADRs reference third-party services and no integration " <>
      "index exists yet."
  end

  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.{Environments, Files, Paths}

  @integrations_index Paths.integrations_index()
  @integrations_dir Paths.integrations_dir()
  @decisions_dir Paths.decisions_dir()

  @doc """
  Generate the integration planning prompt.

  Reads technical decisions, identifies integrations, and builds a prompt
  instructing the agent to draft specs, generate verify scripts, and coordinate
  credential gathering with the user.
  """
  def command(scope, _task) do
    env = scope.environment

    decisions = read_decisions(env)
    existing_specs = read_existing_specs(env)
    existing_index = read_existing_index(env)
    doc_spec = DocumentSpecProjector.project_spec("integration_spec")

    prompt = build_prompt(decisions, existing_specs, existing_index, doc_spec)

    {:ok, prompt}
  end

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

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp read_decisions(env), do: read_md_pairs(env, @decisions_dir)

  defp read_existing_specs(env), do: read_md_pairs(env, @integrations_dir)

  # Glob `*.md` under `dir`, read each, return [{file, content}] dropping unreadable files.
  defp read_md_pairs(env, dir) do
    case Environments.glob(env, Path.join(dir, "*.md")) do
      files when is_list(files) and files != [] ->
        files
        |> Enum.map(&read_file_pair(env, &1))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp read_file_pair(env, file) do
    case Environments.read_file(env, file) do
      {:ok, content} -> {file, content}
      _ -> nil
    end
  end

  defp read_existing_index(env) do
    case Environments.read_file(env, @integrations_index) do
      {:ok, content} when byte_size(content) > 0 -> content
      _ -> nil
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(decisions, existing_specs, existing_index, doc_spec) do
    sections =
      [
        build_header(),
        build_doc_spec_section(doc_spec),
        build_decisions_section(decisions),
        build_existing_specs_section(existing_specs),
        build_existing_index_section(existing_index),
        build_instructions()
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header do
    """
    # Integration Plan: Third-Party Credentials

    You are planning third-party integrations for this project. Your job is to read the
    technical decisions (ADRs), identify integrations that need external credentials
    (OAuth providers, API-key services), and produce structured integration specs with
    verify scripts that prove credentials work.\
    """
  end

  defp build_doc_spec_section(doc_spec) do
    """
    ## Integration Spec Format

    Write each integration spec to `#{@integrations_dir}/{name}.md` following this specification:

    #{doc_spec}\
    """
  end

  defp build_decisions_section([]) do
    """
    ## Technical Decisions

    No decision records found in `#{@decisions_dir}/`. Check if technical strategy has been
    completed. If there are no third-party integrations needed, write an empty integration
    index noting that no integrations are required.\
    """
  end

  defp build_decisions_section(decisions) do
    decision_list =
      Enum.map_join(decisions, "\n\n", fn {file, content} ->
        # Show first ~500 chars of each decision for context
        truncated = String.slice(content, 0, 500)
        "### `#{file}`\n\n#{truncated}"
      end)

    """
    ## Technical Decisions

    The following architecture decisions have been made. Identify any that involve
    third-party services, OAuth providers, or API integrations:

    #{decision_list}\
    """
  end

  defp build_existing_specs_section([]), do: nil

  defp build_existing_specs_section(specs) do
    spec_list = Enum.map_join(specs, "\n", fn {file, _} -> "- `#{file}`" end)

    """
    ## Existing Integration Specs

    The following integration specs already exist. Update rather than recreate:

    #{spec_list}\
    """
  end

  defp build_existing_index_section(nil), do: nil

  defp build_existing_index_section(_content) do
    """
    ## Existing Index

    An integration index already exists at `#{@integrations_index}`. Read it and update
    rather than starting from scratch.\
    """
  end

  defp build_instructions do
    """
    ## Read the playbook

    Read `qa_integration_plan/workflow.md` via the `read_knowledge` MCP
    tool — full six-step procedure (identify integrations from ADRs →
    draft specs → generate verify scripts → request credentials → verify
    → write index), the JSON-output contract for verify scripts, OAuth2
    specifics, anti-patterns.

    ## Done signal

    Stop the session once `#{@integrations_index}` exists and every spec under
    `#{@integrations_dir}/` has a verify script on disk plus `status: verified`.
    The evaluator's state machine will re-check.\
    """
  end

  # ============================================================================
  # Evaluation
  # ============================================================================

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

    Enum.reduce_while(specs, :ok, fn spec, :ok ->
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
    end)
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
