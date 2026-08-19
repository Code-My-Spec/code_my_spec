defmodule CodeMySpec.AgentTasks.SkillRouter do
  @moduledoc """
  Resolves a skill (+ subcommand, + arguments) to a prompt, independent of
  transport.

  Extracted from `CodeMySpecLocalWeb.SkillController`, which called straight
  into `StartAgentTask.run/2` from inside a `Plug.Conn` action — fine for the
  one transport it had, wrong once a second one needed the same routing table.
  `CmsHarness.Web`'s hooks and analysis already draw this line (`CodeMySpec.
  Hooks.*` holds the decision, the controller and the channel handler both call
  it); this is that same split for skills, made necessary by `4396345b` — a
  light-harness session has no reachable `/api/skills/start` at all, because
  nothing under `CmsHarness.Web` could call the logic that used to live only in
  a `Plug.Conn` action.

  `resolve/2` takes the same `scope` a hook decision does and returns a plain
  `{:ok, %{prompt: prompt}} | {:error, reason}` — no `conn`, so both
  `SkillController` (HTTP) and `HarnessProjectChannel` (the channel a harness
  session's requests arrive over) can call it.
  """

  alias CodeMySpec.AgentTasks.StartAgentTask
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Requirements.RequirementGraph

  # skill → {subcommand → session_type}
  # nil subcommand means "no args" default
  @skill_routes %{
    "product" => %{
      "interview" => "story_interview",
      "review" => "story_review",
      "three-amigos" => "three_amigos"
    },
    "design" => %{
      "architecture" => "architecture_design",
      "ui" => "design_ui",
      "strategy" => "technical_strategy"
    },
    "develop" => %{
      "context" => "develop_context",
      "liveview" => "develop_live_view"
    },
    "qa" => %{
      nil => "qa_app",
      "story" => "qa_story",
      "integrations" => "qa_integration_plan",
      "triage" => "triage_issues",
      "fix" => "fix_issues"
    },
    "implement" => %{
      nil => "start_implementation",
      "start" => "start_implementation"
    },
    # "sync" handled as a special route (not an agent task)
    "sync" => %{}
  }

  @type result :: {:ok, map()} | {:error, term()}

  @doc """
  Resolve `params["skill"]` (+ `"subcommand"`/`"module_name"`/`"arguments"`/
  `"external_id"`) against `scope` and return the prompt to follow.

  Same params shape `SkillController.start_skill/2` accepted as a `conn`
  action — `"skill"` is required, everything else optional.
  """
  @spec resolve(CodeMySpec.Users.Scope.t(), map()) :: result()
  def resolve(scope, %{"skill" => skill} = params) do
    {arg_subcommand, arg_module_name} = split_arguments(params["arguments"])

    subcommand = params["subcommand"] || arg_subcommand
    module_name = params["module_name"] || arg_module_name
    external_id = params["external_id"]

    case resolve_route(skill, subcommand) do
      {:ok, :sync} -> run_sync(scope)
      {:ok, :next} -> run_next(scope)
      {:ok, session_type} -> run_task(scope, external_id, session_type, module_name)
      {:error, :stopped} -> {:ok, %{stopped: true}}
      {:error, :unknown_skill} -> {:error, "Unknown skill: #{skill}"}
      {:error, :unknown_subcommand, available} -> unknown_subcommand(skill, subcommand, available)
    end
  end

  # Splits `"ui"` → {"ui", nil}, `"context Foo.Bar"` → {"context", "Foo.Bar"},
  # `nil`/`""` → {nil, nil}. Mirrors the old `bin/skill` script's split
  # semantics so callers stay simple.
  defp split_arguments(nil), do: {nil, nil}

  defp split_arguments(args) when is_binary(args) do
    case String.split(String.trim(args), ~r/\s+/, parts: 2) do
      [""] -> {nil, nil}
      [sub] -> {sub, nil}
      [sub, rest] -> {sub, rest}
    end
  end

  defp resolve_route("sync", nil), do: {:ok, :sync}
  defp resolve_route("implement", "stop"), do: {:error, :stopped}
  defp resolve_route("next", _), do: {:ok, :next}

  defp resolve_route(skill, subcommand) do
    case Map.get(@skill_routes, skill) do
      nil ->
        {:error, :unknown_skill}

      routes ->
        case Map.get(routes, subcommand) do
          nil -> {:error, :unknown_subcommand, Map.keys(routes) -- [nil]}
          session_type -> {:ok, session_type}
        end
    end
  end

  defp unknown_subcommand(skill, subcommand, available),
    do: {:error, "Unknown subcommand '#{subcommand}' for /codemyspec:#{skill}", available}

  defp run_task(scope, external_id, session_type, module_name) do
    args = %{external_id: external_id, session_type: session_type, module_name: module_name}

    case StartAgentTask.run(scope, args) do
      {:ok, prompt, _sync_result} -> {:ok, %{prompt: prompt}}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp run_sync(scope) do
    with {:ok, cwd} <- validate_cwd(scope),
         {:ok, file_result} <- FileSync.sync(scope, base_dir: cwd),
         {:ok, comp_result} <- FileComponentSync.sync_from_files(scope, base_dir: cwd) do
      files = file_result.total_files
      changed = length(file_result.changed_paths)
      components = length(comp_result.all_components)

      {:ok,
       %{
         prompt: """
         Sync complete. #{files} files (#{changed} changed), #{components} components.

         Call `get_next_requirement` to find your next task.
         """
       }}
    else
      {:error, reason} -> {:error, "Sync failed: #{inspect(reason)}"}
    end
  end

  defp validate_cwd(%{cwd: cwd}) when is_binary(cwd), do: {:ok, cwd}

  defp validate_cwd(_) do
    {:error,
     "This harness has no working copy on this machine. Its record carries no root " <>
       "and its project no local_path, so there is nowhere to run. Reconnect the " <>
       "harness from the checkout, or set the project's local path."}
  end

  # Single-step "do the next requirement" gesture. Resolves the next
  # actionable requirement on the server so the agent gets the full context
  # inline and can call `start_task` directly — saves a roundtrip over
  # chaining `get_next_requirement` → `start_task`, and gives the user
  # immediate visibility into what's coming next.
  defp run_next(scope) do
    if scope == nil or scope.active_project == nil do
      {:ok,
       %{
         prompt: """
         No active project linked locally. Run `/codemyspec:init` to bootstrap, \
         or visit http://localhost:4003 to pick a project.
         """
       }}
    else
      next_prompt(scope)
    end
  end

  defp next_prompt(scope) do
    if scope.cwd do
      FileSync.sync(scope, base_dir: scope.cwd)
      FileComponentSync.sync_from_files(scope, base_dir: scope.cwd)
    end

    case RequirementGraph.next_actionable(scope) do
      [] ->
        case RequirementGraph.compute_all(scope) do
          [] -> {:ok, %{prompt: "No requirements found. Run `/codemyspec:sync` to refresh the graph."}}
          _ -> {:ok, %{prompt: "✓ All requirements satisfied. Nothing left to do on this project."}}
        end

      [node | _] ->
        {:ok, %{prompt: render_next_prompt(node)}}
    end
  end

  defp render_next_prompt(node) do
    """
    # Next: #{node.name}

    Your next task is **#{node.name}** for #{node.entity_type} `#{node.entity_name}`.

    Call `start_task` with:
    - `requirement_name`: `"#{node.name}"`
    - `entity_type`: `"#{node.entity_type}"`
    - `entity_id`: `"#{node.entity_id}"`

    `start_task` returns the work prompt for this requirement. Do the work,
    then run `/next` again for the following task.
    """
  end
end
