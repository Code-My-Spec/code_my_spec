defmodule CodeMySpec.TaskHelp do
  @moduledoc """
  Resolves per-task-type educational help for the agent progress view.

  Help teaches a non-engineer what a task type means — a markdown explainer
  plus an optional video — keyed by the task's session-type slug (e.g.
  `CodeMySpec.AgentTasks.ArchitectureDesign` → `architecture_design`).

  Resolution order:

    1. **Project override** — `<cwd>/.code_my_spec/content/help/<slug>.md`
       (+ `.yaml` sidecar), read through the scope environment. Lets a
       project ship its own explainer for a task type.
    2. **Framework default** — `priv/task_help/<slug>.md` (+ `.yaml`),
       shipped with the harness, so every project gets explainers without
       authoring any. The base dir is configurable via
       `config :code_my_spec, :task_help_dir` (used by tests).
    3. `:generic` — no curated content; the surface renders a generic line.

  The explainer body is markdown; the surface renders it to HTML. Content
  is intentionally NOT the marketing/docs corpus — it's standalone
  educational material for non-engineers.

  Contract source of truth: the BDD spex suite at `test/spex/813_*` and
  `test/code_my_spec/task_help_test.exs`.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Environments, CodeMySpec.Users],
    exports: :all

  alias CodeMySpec.Environments
  alias CodeMySpec.TaskHelp.Help
  alias CodeMySpec.Users.Scope

  @override_dir ".code_my_spec/content/help"

  @doc """
  Fetch the educational help for `task_type`, or `:generic` when no curated
  content exists (project override, then framework default).
  """
  @spec fetch(Scope.t(), module()) :: {:ok, Help.t()} | :generic
  def fetch(%Scope{} = scope, task_type) do
    slug = slug_for(task_type)

    with :error <- project_override(scope, slug),
         :error <- framework_default(slug) do
      :generic
    else
      {:ok, body, video_url} ->
        {:ok, %Help{task_type: task_type, body: body, video_url: video_url}}
    end
  end

  # 1. Project-shipped override, read through the scope's environment.
  defp project_override(%Scope{environment: %_{} = env}, slug) do
    case Environments.read_file(env, Path.join(@override_dir, "#{slug}.md")) do
      {:ok, body} -> {:ok, body, env_video_url(env, slug)}
      _ -> :error
    end
  end

  defp project_override(_scope, _slug), do: :error

  # 2. Framework default shipped in priv (or the configured dir under test).
  defp framework_default(slug) do
    case File.read(Path.join(task_help_dir(), "#{slug}.md")) do
      {:ok, body} -> {:ok, body, priv_video_url(slug)}
      _ -> :error
    end
  end

  defp env_video_url(env, slug) do
    case Environments.read_file(env, Path.join(@override_dir, "#{slug}.yaml")) do
      {:ok, content} -> video_url_from_yaml(content)
      _ -> nil
    end
  end

  defp priv_video_url(slug) do
    case File.read(Path.join(task_help_dir(), "#{slug}.yaml")) do
      {:ok, content} -> video_url_from_yaml(content)
      _ -> nil
    end
  end

  defp video_url_from_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, %{"video_url" => url}} when is_binary(url) -> url
      _ -> nil
    end
  end

  defp task_help_dir do
    Application.get_env(:code_my_spec, :task_help_dir) ||
      Application.app_dir(:code_my_spec, "priv/task_help")
  end

  defp slug_for(task_type) do
    task_type
    |> to_string()
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end
end
