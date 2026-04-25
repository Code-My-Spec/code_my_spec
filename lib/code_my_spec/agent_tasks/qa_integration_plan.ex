defmodule CodeMySpec.AgentTasks.QaIntegrationPlan do
  @moduledoc """
  Integration planning agent task.

  Reads technical decisions from `.code_my_spec/architecture/decisions/` to identify
  third-party integrations (OAuth providers, API services), then guides the agent to:

  1. Draft integration specs for each identified integration
  2. Generate verify scripts (and token exchange scripts for OAuth2)
  3. Ask the user for credentials
  4. Run verify scripts to confirm credentials work
  5. Update status to `verified`
  6. Write the integration index

  Two main functions:
  - `command/3` — Builds prompt with integration instructions
  - `evaluate/3` — State machine checking integration spec completeness and verification status

  Sequencing — where this task runs in the requirement graph — is the
  concern of `CodeMySpec.Requirements.RequirementDefinitionData`, not this
  module. This task only describes its own contract.
  """

  def orchestrate(node) do
    "Call `start_task` with requirement `#{node.name}` for #{node.entity_type} `#{node.entity_id}` (#{node.entity_name})"
  end

  alias CodeMySpec.Documents.DocumentSpecProjector
  alias CodeMySpec.{Environments, Paths}

  @integrations_index Paths.integrations_index()
  @integrations_dir Paths.integrations_dir()
  @scripts_dir Paths.qa_scripts_dir()
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
    ## Instructions

    ### Step 1: Identify Integrations

    Read all decision records in `#{@decisions_dir}/`. For each decision that references
    a third-party service (OAuth provider, API service, external API), note:
    - Service name (e.g., twilio, google_calendar, stripe)
    - Auth type: `api_token` or `oauth2`
    - Required credentials (env var names)

    If no integrations are needed, write an integration index stating "No integrations required"
    and stop the session.

    ### Step 2: Draft Integration Specs

    For each identified integration, write a spec to `#{@integrations_dir}/{name}.md`.
    Set initial status to `pending`.

    ### Step 3: Generate Verify Scripts

    For each integration, write a verify script to `#{@scripts_dir}/verify_{name}.sh`.
    The script must:
    - Read credentials from environment variables
    - Make a test API call to prove the credentials work
    - Output structured JSON to stdout:
      ```json
      {"integration": "name", "status": "ok", "details": "description of what was verified"}
      ```
    - On failure:
      ```json
      {"integration": "name", "status": "error", "error": "error message", "details": "what went wrong"}
      ```
    - Make scripts executable (`chmod +x`)

    For OAuth2 integrations, also write `#{@scripts_dir}/exchange_{name}_token.sh`
    that exchanges client credentials for a test token.

    ### Step 4: Request Credentials

    Tell the user exactly which environment variables need to be set, where to get them,
    and how to provide them. Be specific — include URLs to developer consoles.

    ### Step 5: Verify Credentials

    Once the user provides credentials:
    1. Run each verify script
    2. Check the JSON output for `"status": "ok"`
    3. Update the integration spec status to `verified`

    ### Step 6: Write Integration Index

    Write `#{@integrations_index}` summarizing all integrations and their status.

    When all integrations are verified, stop the session so validation can check your work.\
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
