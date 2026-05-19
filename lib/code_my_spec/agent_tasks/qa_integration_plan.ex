defmodule CodeMySpec.AgentTasks.QaIntegrationPlan do
  @moduledoc """
  Identify third-party integrations from ADRs and verify each against real credentials.

  See spec: `.code_my_spec/spec/code_my_spec/agent_tasks/qa_integration_plan.spec.md`.
  """

  def orchestrate(_node) do
    "Identify third-party integrations from technical decisions, draft a " <>
      "spec + verify script per integration, gather credentials from the " <>
      "engineer, and run verify until each spec is `status: verified`. " <>
      "Use when ADRs reference third-party services and no integration " <>
      "index exists yet."
  end

  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.{Environments, Paths}

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
  """
  def evaluate(scope, _task) do
    env = scope.environment
    spec_files = list_spec_files(env)

    if spec_files == [] do
      {:ok, :valid}
    else
      with :ok <- check_index(env),
           :ok <- check_verify_scripts(env, spec_files),
           :ok <- check_verified_status(env, spec_files) do
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

  defp check_index(env) do
    case Environments.read_file(env, @integrations_index) do
      {:ok, content} when byte_size(content) > 0 -> :ok
      {:ok, _} -> {:error, "Integration index is empty. Write `#{@integrations_index}` and stop again."}
      _ -> {:error, "Integration index not found at `#{@integrations_index}`. Write it and stop again."}
    end
  end

  defp list_spec_files(env) do
    case Environments.glob(env, Path.join(@integrations_dir, "*.md")) do
      files when is_list(files) -> files
      _ -> []
    end
  end

  defp check_verify_scripts(_env, []), do: :ok

  defp check_verify_scripts(env, spec_files) do
    Enum.reduce_while(spec_files, :ok, fn file, :ok -> check_one_verify_script(env, file) end)
  end

  defp check_one_verify_script(env, file) do
    case read_verify_script_path(env, file) do
      {:ok, script_path} -> verify_script_exists(env, file, script_path)
      {:error, _} -> {:halt, {:error, "Integration spec `#{file}` has no verify script path. Add a `## Verify Script` section."}}
    end
  end

  defp verify_script_exists(env, file, script_path) do
    if Environments.file_exists?(env, script_path) do
      {:cont, :ok}
    else
      {:halt, {:error, "Verify script `#{script_path}` missing (referenced by `#{file}`). Create it and stop again."}}
    end
  end

  defp check_verified_status(_env, []), do: :ok

  defp check_verified_status(env, spec_files) do
    Enum.reduce_while(spec_files, :ok, fn file, :ok -> check_one_verified(env, file) end)
  end

  defp check_one_verified(env, file) do
    case Environments.read_file(env, file) do
      {:ok, content} -> verified_status(file, content)
      _ -> {:halt, {:error, "Cannot read integration spec `#{file}`."}}
    end
  end

  defp verified_status(file, content) do
    if String.contains?(String.downcase(content), "verified") do
      {:cont, :ok}
    else
      {:halt, {:error, "Integration `#{file}` is not yet verified. Run the verify script and update the status."}}
    end
  end

  defp read_verify_script_path(env, spec_file) do
    case Environments.read_file(env, spec_file) do
      {:ok, content} ->
        case Regex.run(~r/##\s*Verify Script\s*\n+`?([^\n`]+)`?/i, content) do
          [_, path] -> {:ok, String.trim(path)}
          _ -> {:error, "No verify script path found"}
        end

      _ ->
        {:error, "Cannot read spec file"}
    end
  end
end
