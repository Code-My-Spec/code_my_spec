defmodule CodeMySpec.TaskHelp do
  @moduledoc """
  Resolves per-task help content for the agent progress view.

  Maps an agent task type to a curated help document on disk
  (`.code_my_spec/content/<task_type>.md`) plus its `.yaml` sidecar
  (carrying an optional `video_url`). Major task types that have a
  curated document return `{:ok, %Help{}}`; every other task type falls
  back to `:generic`, leaving the surface to render a generic
  explanation.

  All reads go through the scope's environment, so the same lookup works
  against the real filesystem in production and the in-memory environment
  under test.

  Contract source of truth: the BDD spex suite at `test/spex/813_*`.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.TaskHelp.Help
  alias CodeMySpec.Users.Scope

  @content_dir ".code_my_spec/content"

  @doc """
  Fetch the curated help for `task_type`, or `:generic` when no curated
  document exists for it.

  `task_type` is the task's session-type module (e.g.
  `CodeMySpec.AgentTasks.ArchitectureDesign`); its final segment, snake
  cased, is the content document's slug (`architecture_design`).
  """
  @spec fetch(Scope.t(), module()) :: {:ok, Help.t()} | :generic
  def fetch(%Scope{environment: environment}, task_type) do
    slug = slug_for(task_type)

    case Environments.read_file(environment, content_path(slug, "md")) do
      {:ok, body} ->
        {:ok, %Help{task_type: task_type, body: body, video_url: video_url(environment, slug)}}

      {:error, _reason} ->
        :generic
    end
  end

  defp video_url(environment, slug) do
    with {:ok, content} <- Environments.read_file(environment, content_path(slug, "yaml")),
         {:ok, %{"video_url" => url}} when is_binary(url) <-
           YamlElixir.read_from_string(content) do
      url
    else
      _ -> nil
    end
  end

  defp content_path(slug, extension), do: Path.join(@content_dir, "#{slug}.#{extension}")

  defp slug_for(task_type) do
    task_type
    |> to_string()
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end
end
