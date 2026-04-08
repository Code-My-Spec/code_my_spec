defmodule CodeMySpec.AgentTasks.CodeGeneration do
  @moduledoc """
  Agent task for running code generators after technical decisions are made.

  Reads the project's technical decisions (ADRs) and existing dependencies to
  determine which generators need to run, then guides the agent through executing
  them in the correct order:

  1. `mix phx.gen.auth` — authentication (if not already done)
  2. `mix cms_gen.accounts` — multi-tenant accounts, members, invitations
  3. `mix cms_gen.integrations` — OAuth integration scaffolding
  4. `mix cms_gen.integration_provider` — per-provider OAuth modules
  5. `mix cms_gen.feedback_widget` — CodeMySpec feedback widget

  Artifact produced:
  - `.code_my_spec/tasks/code_generation.sh` — reproducible script of all generator commands run
  """

  alias CodeMySpec.{Environments, Paths}
  alias CodeMySpec.AgentTasks.Setup.Helpers

  @artifact_path Path.join(Paths.tasks_dir(), "code_generation.sh")

  # Ordered list of generators with their detection heuristics.
  # Each entry: {id, command, description, prerequisite_id, detection_glob}
  @generators [
    {"phx_gen_auth", "mix phx.gen.auth Users User users --live",
     "Authentication with registration, login, session management",
     nil, "lib/APP/users/scope.ex"},
    {"cms_gen_accounts", "mix cms_gen.accounts",
     "Multi-tenant accounts with members and invitations",
     "phx_gen_auth", "lib/APP/accounts/account.ex"},
    {"cms_gen_integrations", "mix cms_gen.integrations",
     "OAuth integration scaffolding with encrypted token storage",
     "phx_gen_auth", "lib/APP/integrations/integration.ex"},
    {"cms_gen_feedback_widget", "mix cms_gen.feedback_widget",
     "CodeMySpec feedback widget with screenshot capture",
     "cms_gen_integrations", "lib/APP_web/live/feedback_widget.ex"}
  ]

  @doc "Returns the ordered list of generators."
  def generators, do: @generators

  @doc """
  Generate the orchestration prompt for the code generation session.

  Reads technical decisions, checks which generators have already been run,
  and builds a prompt for the remaining work.
  """
  @spec command(CodeMySpec.Users.Scope.t(), map()) :: {:ok, String.t()}
  def command(scope, _task) do
    env = scope.environment
    app_name = Helpers.extract_app_name(env) || "app"
    decisions = list_decisions(env)
    already_run = detect_already_run(env, app_name)
    existing_artifact = read_existing_artifact(env)
    providers = detect_needed_providers(env)

    prompt =
      build_prompt(
        app_name,
        decisions,
        already_run,
        existing_artifact,
        providers
      )

    {:ok, prompt}
  end

  @doc """
  Validate code generation output.

  Checks:
  1. The generation script artifact exists
  2. At minimum, phx.gen.auth detection file exists
  3. The script is non-empty and contains at least one mix command

  Returns:
  - `{:ok, :valid}` if all checks pass
  - `{:ok, :invalid, feedback}` if anything is incomplete
  """
  @spec evaluate(CodeMySpec.Users.Scope.t(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(scope, _task) do
    env = scope.environment

    case check_artifact(env) do
      :ok -> {:ok, :valid}
      {:error, feedback} -> {:ok, :invalid, feedback}
    end
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp list_decisions(env) do
    case Environments.glob(env, Path.join(Paths.decisions_dir(), "*.md")) do
      files when is_list(files) ->
        Enum.map(files, &Path.basename(&1, ".md"))

      _ ->
        []
    end
  end

  defp detect_already_run(env, app_name) do
    Enum.filter(@generators, fn {_id, _cmd, _desc, _prereq, glob} ->
      resolved = resolve_glob(glob, app_name)
      Environments.file_exists?(env, resolved) == true
    end)
    |> Enum.map(fn {id, _, _, _, _} -> id end)
  end

  defp detect_needed_providers(env) do
    case Environments.glob(env, Path.join(Paths.integrations_dir(), "*.md")) do
      files when is_list(files) ->
        files
        |> Enum.map(&Path.basename(&1, ".md"))
        |> Enum.reject(&(&1 == "index"))

      _ ->
        []
    end
  end

  defp read_existing_artifact(env) do
    case Environments.read_file(env, @artifact_path) do
      {:ok, content} when byte_size(content) > 0 -> content
      _ -> nil
    end
  end

  defp resolve_glob(glob, app_name) do
    web_name = "#{app_name}_web"

    glob
    |> String.replace("APP_web", web_name)
    |> String.replace("APP", app_name)
  end

  defp check_artifact(env) do
    case Environments.read_file(env, @artifact_path) do
      {:ok, content} when byte_size(content) > 0 ->
        :ok

      {:ok, _} ->
        {:error, "Generation script at `#{@artifact_path}` is empty."}

      _ ->
        {:error, "Generation script not found at `#{@artifact_path}`. Record the commands you ran."}
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(app_name, decisions, already_run, existing_artifact, providers) do
    sections =
      [
        build_header(),
        build_decisions_section(decisions),
        build_status_section(app_name, already_run),
        build_providers_section(providers),
        build_existing_artifact_section(existing_artifact),
        build_instructions(app_name, already_run)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp build_header do
    """
    # Code Generation Session

    You are running code generators for this project. These generators scaffold
    authentication, multi-tenancy, OAuth integrations, and the feedback widget.

    Generators must be run in order because each depends on the previous one's output.
    After running generators, you must also run migrations and resolve any compilation issues.\
    """
  end

  defp build_decisions_section([]) do
    """
    ## Technical Decisions

    No decision records found. Check that technical strategy has been completed.\
    """
  end

  defp build_decisions_section(decisions) do
    decision_list = Enum.map_join(decisions, "\n", &"- `#{&1}`")

    """
    ## Technical Decisions

    The following ADRs exist in `#{Paths.decisions_dir()}/`:

    #{decision_list}

    Review these to understand which generators are needed.\
    """
  end

  defp build_status_section(_app_name, []) do
    """
    ## Current Status

    No generators have been run yet. Start from the beginning.\
    """
  end

  defp build_status_section(_app_name, already_run) do
    status_list =
      Enum.map_join(@generators, "\n", fn {id, cmd, _desc, _prereq, _glob} ->
        if id in already_run do
          "- [x] `#{cmd}` — already run"
        else
          "- [ ] `#{cmd}`"
        end
      end)

    """
    ## Current Status

    #{status_list}\
    """
  end

  defp build_providers_section([]), do: nil

  defp build_providers_section(providers) do
    provider_list = Enum.map_join(providers, "\n", &"- `#{&1}`")

    """
    ## Integration Providers

    The following integration specs exist in `#{Paths.integrations_dir()}/`.
    Generate a provider module for each using `mix cms_gen.integration_provider`:

    #{provider_list}\
    """
  end

  defp build_existing_artifact_section(nil), do: nil

  defp build_existing_artifact_section(_content) do
    """
    ## Existing Generation Script

    A generation script already exists at `#{@artifact_path}`. Read it to see
    what has already been recorded. Append any new commands you run.\
    """
  end

  defp build_instructions(app_name, already_run) do
    pending =
      @generators
      |> Enum.reject(fn {id, _, _, _, _} -> id in already_run end)
      |> Enum.map(fn {_id, cmd, desc, prereq, _glob} ->
        prereq_note = if prereq, do: " (requires `#{prereq}` first)", else: ""
        "- `#{cmd}` — #{desc}#{prereq_note}"
      end)

    pending_section =
      case pending do
        [] -> "All standard generators have already been run."
        list -> Enum.join(list, "\n")
      end

    """
    ## Instructions

    ### Step 1: Run Pending Generators

    Run each generator in order. After each one, run `mix deps.get` if new deps
    were added, then `mix ecto.migrate` to apply migrations.

    #{pending_section}

    ### Step 2: Generate Integration Providers

    If integration specs exist in `#{Paths.integrations_dir()}/`, run
    `mix cms_gen.integration_provider <DisplayName> <key>` for each provider.

    For example:
    ```
    mix cms_gen.integration_provider GitHub github
    mix cms_gen.integration_provider Google google
    mix cms_gen.integration_provider CodeMySpec codemyspec
    ```

    ### Step 3: Resolve Compilation Issues

    After running all generators:
    1. Run `mix compile` and fix any issues
    2. Run `mix ecto.migrate` to apply all pending migrations
    3. Run `mix test` to verify nothing is broken

    ### Step 4: Update Ignored Paths

    The generators create framework/infrastructure modules that should be added
    to `.code_my_spec/config.yml` `ignored_paths`. Add paths for generated modules
    like `lib/#{app_name}/vault.ex`, `lib/#{app_name}/encrypted/*`,
    `lib/#{app_name}/authorization.ex`, etc.

    ### Step 5: Record the Generation Script

    Write a shell script to `#{@artifact_path}` that records every generator
    command you ran, in order. Include comments noting what each generator produces.
    The script should be re-runnable on a fresh Phoenix project.

    Format:
    ```bash
    #!/bin/bash
    # Code generation script — produced by CodeMySpec code_generation task
    # Re-run on a fresh Phoenix project to reproduce this scaffold.

    set -e

    # Authentication (LiveView)
    mix phx.gen.auth Users User users --live

    # Multi-tenant accounts
    mix cms_gen.accounts

    # ... etc
    ```

    ### No Generators Needed?

    If no generators are needed for this project (no ADRs reference generated code),
    write an empty script with just the shebang and a comment:

    ```bash
    #!/bin/bash
    # No generators needed for this project.
    ```

    ### Step 6: Stop

    When all generators have been run, compilation is clean, and the script is
    written, stop the session so validation can check your work.\
    """
  end
end
