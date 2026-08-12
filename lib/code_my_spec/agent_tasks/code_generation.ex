defmodule CodeMySpec.AgentTasks.CodeGeneration do
  @moduledoc """
  Run CodeMySpec generators (phx.gen.auth + cms_gen.*) to scaffold a new project.

  See spec: `.code_my_spec/spec/code_my_spec/agent_tasks/code_generation.spec.md`.
  """

  alias CodeMySpec.AgentTasks.Setup.Helpers
  alias CodeMySpec.{Environments, Paths}

  @artifact_path Path.join(Paths.tasks_dir(), "code_generation.sh")

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
    # Not `cms_gen.feedback_widget`, which is deprecated in the generators
    # package in favour of this one and is a different thing besides: it talks
    # OAuth/REST and needs `cms_gen.integrations` first, while the support
    # widget rides the project's deploy key. Provisioning's widget step proves
    # a deploy-key widget, so scaffolding the OAuth one meant the step verified
    # something no new project had.
    {"cms_gen_support_widget", "mix cms_gen.support_widget",
     "CodeMySpec support widget — chat and report-a-problem over the deploy key",
     "cms_gen_accounts", "lib/APP_web/live/support_widget_live.ex"}
  ]

  @doc "Returns the ordered list of generators."
  def generators, do: @generators

  @doc """
  One-line description surfaced by the requirement graph when this task is
  the next thing to do.
  """
  def dispatch(_node) do
    "Run CodeMySpec generators (phx.gen.auth, cms_gen.*) to scaffold auth, " <>
      "multi-tenancy, OAuth integrations, and the support widget for this " <>
      "project. Produces an idempotent bash script at " <>
      "`.code_my_spec/tasks/code_generation.sh`. Use when ADRs reference " <>
      "generated code and generators haven't been run yet."
  end

  @doc """
  Generate the prompt for the code generation session.

  Inspects the current project state — ADRs, which generators have already
  run, which integration providers are declared — and renders a prompt that
  points the agent at the knowledge MCP playbook and lists what's left to do.
  """
  @spec command(CodeMySpec.Users.Scope.t(), map()) :: {:ok, String.t()}
  def command(scope, _task) do
    env = scope.environment
    app_name = Helpers.extract_app_name(env) || "app"
    decisions = list_decisions(env)
    already_run = detect_already_run(env, app_name)
    existing_artifact = read_existing_artifact(env)
    providers = detect_needed_providers(env)

    prompt = build_prompt(scope, decisions, already_run, existing_artifact, providers)
    {:ok, prompt}
  end

  @doc """
  Validate code generation output.

  Checks for the existence and non-emptiness of the reproducible bash script
  at `.code_my_spec/tasks/code_generation.sh`. Compile and test failures
  don't gate the task.
  """
  @spec evaluate(CodeMySpec.Users.Scope.t(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(scope, _task) do
    case check_artifact(scope.environment) do
      :ok -> {:ok, :valid}
      {:error, feedback} -> {:ok, :invalid, feedback}
    end
  end

  # State inspection — the dynamic-context win that justifies an agent_task
  # over a static skill.

  defp list_decisions(env) do
    case Environments.glob(env, Path.join(Paths.decisions_dir(), "*.md")) do
      files when is_list(files) -> Enum.map(files, &Path.basename(&1, ".md"))
      _ -> []
    end
  end

  defp detect_already_run(env, app_name) do
    @generators
    |> Enum.filter(fn {_id, _cmd, _desc, _prereq, glob} ->
      Environments.file_exists?(env, resolve_glob(glob, app_name)) == true
    end)
    |> Enum.map(fn {id, _, _, _, _} -> id end)
  end

  defp detect_needed_providers(env) do
    case Environments.glob(env, Path.join(Paths.integrations_dir(), "*.md")) do
      files when is_list(files) ->
        files |> Enum.map(&Path.basename(&1, ".md")) |> Enum.reject(&(&1 == "index"))

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
        {:error,
         "Generation script not found at `#{@artifact_path}`. Record the commands you ran."}
    end
  end

  # Prompt assembly. Static procedural detail lives in the framework knowledge
  # library at `cms_generators/` — read via the `read_knowledge` MCP tool
  # rather than inlined here.

  defp build_prompt(scope, decisions, already_run, existing_artifact, providers) do
    [
      header_section(),
      decisions_section(decisions),
      status_section(already_run),
      providers_section(providers),
      existing_artifact_section(existing_artifact),
      playbook_section(),
      pending_section(already_run),
      support_widget_secrets_section(scope, already_run),
      done_signal_section()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp header_section do
    """
    # Code Generation Session

    You are running CodeMySpec generators to scaffold auth, multi-tenancy,
    OAuth integrations, and the support widget for this project. Order matters
    — each generator depends on the previous one's output.\
    """
  end

  defp decisions_section([]) do
    """
    ## Technical Decisions

    No ADRs found in `#{Paths.decisions_dir()}/`. Confirm `technical_strategy`
    has been completed before continuing.\
    """
  end

  defp decisions_section(decisions) do
    list = Enum.map_join(decisions, "\n", &"- `#{&1}`")

    """
    ## Technical Decisions

    ADRs in `#{Paths.decisions_dir()}/`:

    #{list}

    Review these to confirm which generators apply.\
    """
  end

  defp status_section([]) do
    """
    ## Current Status

    No generators have run yet.\
    """
  end

  defp status_section(already_run) do
    list =
      Enum.map_join(@generators, "\n", fn {id, cmd, _, _, _} ->
        if id in already_run, do: "- [x] `#{cmd}` — already run", else: "- [ ] `#{cmd}`"
      end)

    """
    ## Current Status

    #{list}\
    """
  end

  defp providers_section([]), do: nil

  defp providers_section(providers) do
    list = Enum.map_join(providers, "\n", &"- `#{&1}`")

    """
    ## Integration Providers

    Specs exist in `#{Paths.integrations_dir()}/`:

    #{list}

    Run `mix cms_gen.integration_provider <DisplayName> <key>` for each.
    See the playbook for the command format.\
    """
  end

  defp existing_artifact_section(nil), do: nil

  defp existing_artifact_section(_content) do
    """
    ## Existing Generation Script

    A script already exists at `#{@artifact_path}`. The user may have
    hand-edited it — confirm before overwriting. The new script should be
    rewritten from the currently-detected project state.\
    """
  end

  defp playbook_section do
    """
    ## Read the playbook first

    Read these two files via the `read_knowledge` MCP tool before running
    any generators:

    - `cms_generators/workflow.md` — generator order, post-generation steps
      (deps/migrate/compile/test), integration provider command pattern,
      and the support widget multi-step setup procedure.
    - `cms_generators/script-format.md` — reproducible bash script format
      and rules.

    ## Case-module namespace clash (phx.gen.auth)

    Project setup renames the test case modules to `AppTest.ConnCase` /
    `AppTest.DataCase`, but Phoenix generators hardcode the default names
    (`AppWeb.ConnCase` / `App.DataCase`) in every test they emit. Before
    running `mix phx.gen.auth`, make sure the compatibility shims exist
    (`test/support/conn_case_compat.ex` / `data_case_compat.ex` — modules
    named `AppWeb.ConnCase` / `App.DataCase` whose `__using__` forwards to
    the `AppTest.*` case). If they're missing, create them; otherwise the
    generated test suite will not compile.\
    """
  end

  defp pending_section(already_run) do
    pending =
      @generators
      |> Enum.reject(fn {id, _, _, _, _} -> id in already_run end)
      |> Enum.map(fn {_id, cmd, desc, prereq, _glob} ->
        prereq_note = if prereq, do: " (requires `#{prereq}` first)", else: ""
        "- `#{cmd}` — #{desc}#{prereq_note}"
      end)

    body =
      case pending do
        [] -> "All standard generators have already been run."
        list -> Enum.join(list, "\n")
      end

    """
    ## Pending Generators

    #{body}\
    """
  end

  # Surface this whenever the task runs — the support widget is part of the
  # standard scaffold, so the engineer will need credentials regardless of
  # whether the widget generator has already run or is still pending.
  defp support_widget_secrets_section(scope, _already_run) do
    project_url = project_url(scope)

    """
    ## Support widget — credentials (relay to engineer)

    The support widget connects server-side with the project's **deploy key**
    — the same key content sync uses. There is no OAuth client id or secret;
    the key is self-identifying, and it never reaches the browser.

    The agent can apply the generator's post-gen edits (deps, supervision
    tree, root.html.heex, runtime config) automatically — see the playbook.

    Tell the engineer:

    1. Open #{project_url}
    2. Copy the project's deploy key.
    3. Set it as `DEPLOY_KEY` in the deployed environment, alongside
       `CODEMYSPEC_WIDGET_URL`. Read `config/runtime.exs` after wiring to
       confirm the names.

    Without the key in env the widget compiles cleanly, renders, and connects
    to nothing — every message a visitor sends is dropped, and the page gives
    no sign of it. Surface this in your summary message; don't bury it in
    script comments.\
    """
  end

  defp project_url(scope) do
    base = Application.get_env(:code_my_spec, :base_url, "https://codemyspec.com")
    uuid = scope.active_project_id || "<your-project-uuid>"
    "#{base}/app/projects/#{uuid}"
  end

  defp done_signal_section do
    """
    ## Done signal

    Write the reproducible bash script to `#{@artifact_path}` capturing every
    generator command you ran. The evaluator checks for the file's existence
    and non-emptiness. See the playbook for the script format.\
    """
  end
end
