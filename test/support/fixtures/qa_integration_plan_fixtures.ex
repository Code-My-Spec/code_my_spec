defmodule CodeMySpec.QaIntegrationPlanFixtures do
  @moduledoc """
  Seeds an `InMemoryEnvironment` for BDD specs covering the
  `CodeMySpec.AgentTasks.QaIntegrationPlan` task. Used by the
  "Verified third-party integrations" story.

  ## Design

  QaIntegrationPlan is a prompt-builder + evaluator that reads four
  filesystem sources and writes nothing on its own:

  | Source                                               | Purpose                                    |
  |------------------------------------------------------|--------------------------------------------|
  | `mix.exs`                                            | Anchor (so other tasks can detect the app) |
  | `.code_my_spec/architecture/decisions/*.md`          | Identify which integrations are needed     |
  | `.code_my_spec/integrations/*.md`                    | Existing specs to update vs. recreate      |
  | `.code_my_spec/integrations.md`                      | Index — gate artifact for evaluation       |
  | `.code_my_spec/qa/scripts/verify_*.sh`               | Per-integration verify scripts             |

  Each public function here writes ONE of those sources or a
  realistic composite. Scenarios compose them.

  ## Realism

  Helpers write content that mirrors what a real session produces:

  - Decision records carry an explicit `## Decision` section that
    names the service, auth type, and required env vars — enough for
    the agent to identify the integration heuristically.
  - Integration specs include `## Status`, `## Auth Type`,
    `## Required Credentials`, and `## Verify Script` sections.
    The Verify Script section uses the backtick-wrapped path form
    that `read_verify_script_path/2` expects.
  - Verify scripts are real bash with the structured-JSON output
    contract — exit 1 with `status: error` when env vars are missing,
    exit 0 with `status: ok` after the (mocked) API call.
  - The integration index uses the canonical "table of integrations"
    shape so retrofit scenarios assert on real content.

  ## Status text

  `check_verified_status/2` does a case-insensitive substring match
  on the spec content. Any spec containing the literal "verified"
  passes. To produce a *not-yet-verified* spec, use the `pending`
  variant. To produce a verified spec, use the `verified` variant —
  the word "verified" appears verbatim in the `## Status` section.

  ## Composite happy state

  `with_verified_integration/2` writes spec + verify script + index
  in one call — the full happy state for evaluate_task to pass.

  ## Reset

  Delegates to `SetupFixtures.reset/1` (in-memory env wipe).
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.SetupFixtures

  @app_name "my_app"
  @app_mod "MyApp"

  @decisions_dir ".code_my_spec/architecture/decisions"
  @integrations_dir ".code_my_spec/integrations"
  @integrations_index ".code_my_spec/integrations.md"
  @scripts_dir ".code_my_spec/qa/scripts"

  # ──────────────────────────────────────────────────────────────────────────
  # Path helpers
  # ──────────────────────────────────────────────────────────────────────────

  @doc "Decisions directory path."
  @spec decisions_dir() :: String.t()
  def decisions_dir, do: @decisions_dir

  @doc "Integrations directory path."
  @spec integrations_dir() :: String.t()
  def integrations_dir, do: @integrations_dir

  @doc "Integrations index file path."
  @spec integrations_index() :: String.t()
  def integrations_index, do: @integrations_index

  @doc "QA scripts directory path."
  @spec scripts_dir() :: String.t()
  def scripts_dir, do: @scripts_dir

  @doc "Path of the integration spec for `name`."
  @spec integration_spec_path(String.t()) :: String.t()
  def integration_spec_path(name), do: "#{@integrations_dir}/#{name}.md"

  @doc "Path of the verify script for `name`."
  @spec verify_script_path(String.t()) :: String.t()
  def verify_script_path(name), do: "#{@scripts_dir}/verify_#{name}.sh"

  @doc "Path of the OAuth2 token-exchange script for `name`."
  @spec exchange_script_path(String.t()) :: String.t()
  def exchange_script_path(name), do: "#{@scripts_dir}/exchange_#{name}_token.sh"

  # ──────────────────────────────────────────────────────────────────────────
  # Baseline / reset
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Write a baseline `mix.exs` so app-name detection succeeds. Idempotent —
  only writes if `mix.exs` is absent.
  """
  @spec with_baseline_project(Environment.t()) :: :ok
  def with_baseline_project(env) do
    unless Environments.file_exists?(env, "mix.exs") do
      Environments.write_file(env, "mix.exs", """
      defmodule #{@app_mod}.MixProject do
        use Mix.Project

        def project do
          [app: :#{@app_name}, version: "0.1.0", deps: deps()]
        end

        def application do
          [mod: {#{@app_mod}.Application, []}, extra_applications: [:logger]]
        end

        defp deps, do: []
      end
      """)
    end

    :ok
  end

  @doc "Wipe the in-memory env. Delegates to SetupFixtures."
  @spec reset(Environment.t()) :: :ok
  defdelegate reset(env), to: SetupFixtures

  # ──────────────────────────────────────────────────────────────────────────
  # Decision records
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Write a decision record (ADR) that references a third-party `service`
  so the planner can identify it as an integration.

  Options:
  - `:title` — override the ADR title (default: derived from service)
  - `:auth_type` — `"api_token"` (default) or `"oauth2"`
  - `:purpose` — short phrase used in Context (default: "third-party integration")
  - `:env_vars` — required environment variable names (default: `<SERVICE>_API_KEY`)

  Use `:auth_type, "oauth2"` to model integrations that should also
  trigger token-exchange script instructions in the prompt.
  """
  @spec with_decision_for_service(Environment.t(), String.t(), keyword()) :: :ok
  def with_decision_for_service(env, service, opts \\ []) do
    title = Keyword.get(opts, :title, "Use #{display(service)}")
    auth_type = Keyword.get(opts, :auth_type, "api_token")
    purpose = Keyword.get(opts, :purpose, "third-party integration")
    env_vars = Keyword.get(opts, :env_vars, "#{String.upcase(service)}_API_KEY")

    Environments.write_file(env, "#{@decisions_dir}/#{service}.md", """
    # #{title}

    ## Status
    Accepted

    ## Context
    The project needs #{purpose} via #{display(service)}.

    ## Decision
    Use #{display(service)}. Auth type: #{auth_type}. Required env vars: #{env_vars}.

    ## Consequences
    Integration spec and credential-verify script for #{service} must be
    produced before code generation runs.
    """)

    :ok
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Integration specs
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Write a *verified* integration spec for `name` — Status `verified`,
  carries a `## Verify Script` section. Does NOT write the verify
  script itself; pair with `with_verify_script/2` for the full happy
  state, or use `with_verified_integration/2` for the composite.
  """
  @spec with_verified_integration_spec(Environment.t(), String.t()) :: :ok
  def with_verified_integration_spec(env, name) do
    write_integration_spec(env, name, status_label: "verified")
  end

  @doc """
  Write a *pending* integration spec for `name` — Status `pending`,
  carries a `## Verify Script` section but credentials have not yet
  been verified.
  """
  @spec with_pending_integration_spec(Environment.t(), String.t()) :: :ok
  def with_pending_integration_spec(env, name) do
    write_integration_spec(env, name, status_label: "pending")
  end

  @doc """
  Write an integration spec for `name` that is missing the
  `## Verify Script` section — the failure mode for Rule 4's
  "spec without verify script" branch.
  """
  @spec with_integration_spec_missing_verify_script(Environment.t(), String.t()) :: :ok
  def with_integration_spec_missing_verify_script(env, name) do
    Environments.write_file(env, integration_spec_path(name), """
    # #{display(name)} Integration

    ## Status
    pending

    ## Auth Type
    api_token

    ## Required Credentials
    #{String.upcase(name)}_API_KEY — get from https://#{name}.example/console/api-keys

    Note: this spec intentionally lacks a Verify Script section to
    exercise the corresponding evaluator branch.
    """)

    :ok
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Verify scripts
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Write a verify script at `.code_my_spec/qa/scripts/verify_{name}.sh`
  that emits the structured-JSON output contract the integration spec
  format mandates. The script is realistic but not actually executable
  in the in-memory env — its presence is what gates evaluation.
  """
  @spec with_verify_script(Environment.t(), String.t()) :: :ok
  def with_verify_script(env, name) do
    upper = String.upcase(name)

    Environments.write_file(env, verify_script_path(name), """
    #!/bin/bash
    # Verify #{name} credentials.
    set -e

    if [ -z "$#{upper}_API_KEY" ]; then
      echo '{"integration": "#{name}", "status": "error", "error": "missing #{upper}_API_KEY"}'
      exit 1
    fi

    # Real implementation would make an authenticated probe call here.
    echo '{"integration": "#{name}", "status": "ok", "details": "credentials accepted"}'
    """)

    :ok
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Integrations index
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Write a populated integrations index summarizing one or more
  integrations. Pass `topics` as a list of atoms or strings; each
  becomes a row in the index table. With no `topics`, writes a
  minimal table header.
  """
  @spec with_integration_index(Environment.t()) :: :ok
  def with_integration_index(env), do: with_integration_index(env, [])

  @spec with_integration_index(Environment.t(), [String.t()]) :: :ok
  def with_integration_index(env, topics) when is_list(topics) do
    rows =
      Enum.map_join(topics, "\n", fn name ->
        "| `#{name}` | api_token | verified |"
      end)

    rows_block = if rows == "", do: "", else: "\n#{rows}"

    Environments.write_file(env, @integrations_index, """
    # Integrations Index

    | Name | Auth Type | Status |
    |---|---|---|#{rows_block}
    """)

    :ok
  end

  @doc """
  Write an explicitly empty integrations index — a "no integrations
  required" marker. Use for the empty-pipeline happy path scenario.
  """
  @spec with_empty_integration_index(Environment.t()) :: :ok
  def with_empty_integration_index(env) do
    Environments.write_file(env, @integrations_index, """
    # Integrations Index

    No third-party integrations are required for this project.
    """)

    :ok
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Composites
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Set up the full happy state for one integration: verified spec +
  verify script + index entry. Equivalent to:

      with_verified_integration_spec(env, name)
      with_verify_script(env, name)
      with_integration_index(env, [name])
  """
  @spec with_verified_integration(Environment.t(), String.t()) :: :ok
  def with_verified_integration(env, name) do
    with_verified_integration_spec(env, name)
    with_verify_script(env, name)
    with_integration_index(env, [name])
    :ok
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Read helpers
  # ──────────────────────────────────────────────────────────────────────────

  @doc "Read an integration spec. Returns content or nil."
  @spec read_integration_spec(Environment.t(), String.t()) :: String.t() | nil
  def read_integration_spec(env, name) do
    case Environments.read_file(env, integration_spec_path(name)) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  @doc "Read the integrations index. Returns content or nil."
  @spec read_integration_index(Environment.t()) :: String.t() | nil
  def read_integration_index(env) do
    case Environments.read_file(env, @integrations_index) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  @doc "True if an integration spec exists for `name`."
  @spec integration_spec_exists?(Environment.t(), String.t()) :: boolean()
  def integration_spec_exists?(env, name) do
    Environments.file_exists?(env, integration_spec_path(name)) == true
  end

  @doc "True if the integrations index file exists."
  @spec integration_index_exists?(Environment.t()) :: boolean()
  def integration_index_exists?(env) do
    Environments.file_exists?(env, @integrations_index) == true
  end

  @doc "True if the verify script for `name` exists at the canonical path."
  @spec verify_script_exists?(Environment.t(), String.t()) :: boolean()
  def verify_script_exists?(env, name) do
    Environments.file_exists?(env, verify_script_path(name)) == true
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Internals
  # ──────────────────────────────────────────────────────────────────────────

  defp write_integration_spec(env, name, opts) do
    status_label = Keyword.fetch!(opts, :status_label)
    upper = String.upcase(name)

    # Body intentionally avoids the literal word "verified" outside the
    # Status section. `check_verified_status/2` does a case-insensitive
    # substring match (a known brittle contract) — leaking "verified"
    # into the body of a pending spec would falsely satisfy the check.
    Environments.write_file(env, integration_spec_path(name), """
    # #{display(name)} Integration

    ## Status
    #{status_label}

    ## Auth Type
    api_token

    ## Required Credentials
    #{upper}_API_KEY — get from https://#{name}.example/console/api-keys

    ## Verify Script
    `#{verify_script_path(name)}`

    ## Notes
    Run the verify script after credentials are loaded into the
    environment. The script emits structured JSON to stdout — `ok`
    on success, `error` on failure.
    """)

    :ok
  end

  defp display(name) do
    name
    |> String.split(["_", "-"])
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
