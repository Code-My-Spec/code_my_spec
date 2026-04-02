defmodule CodeMySpec.McpServers.Hexdocs.Tools.EmbedHexdocs do
  @moduledoc """
  Extract and embed documentation from compiled hex dependencies.

  Reads EEP-48 docs directly from BEAM files in the project's _build/ directory.
  No network access required — uses the exact versions already compiled locally.

  Specify a package name to embed a single dep, or omit to embed all deps.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Embeddings.{DocExtractor, EmbeddingService}
  alias CodeMySpec.McpServers.Validators

  schema do
    field :package, :string,
      description: "Hex package name to embed (e.g. 'phoenix'). Omit to embed all deps."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      cwd = scope.cwd || scope.environment.cwd
      build_dir = Path.join(cwd, "_build/dev")
      project_id = scope.active_project_id

      case params do
        %{"package" => package} when is_binary(package) and package != "" ->
          result = embed_package(project_id, build_dir, package)
          {:reply, text_response(format_single(package, result)), frame}

        _ ->
          results = embed_all(project_id, build_dir)
          {:reply, text_response(format_all(results)), frame}
      end
    else
      {:error, reason} ->
        {:reply, error_response("#{reason}"), frame}
    end
  end

  defp embed_package(project_id, build_dir, package) do
    case DocExtractor.extract(build_dir, package) do
      {:ok, docs} when docs != [] ->
        source = "hexdocs:#{package}"

        results =
          Enum.map(docs, fn %{module: mod, markdown: markdown} ->
            path = inspect(mod)
            EmbeddingService.embed_file(project_id, source, path, markdown)
          end)

        embedded = Enum.sum(for {:ok, r} <- results, do: r.embedded)
        skipped = Enum.sum(for {:ok, r} <- results, do: r.skipped)

        {:ok, %{embedded: embedded, skipped: skipped}}

      {:ok, _} ->
        {:ok, %{embedded: 0, skipped: 0, note: "No docs found"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp embed_all(project_id, build_dir) do
    deps = DocExtractor.list_deps(build_dir)

    Enum.map(deps, fn dep ->
      {dep, embed_package(project_id, build_dir, dep)}
    end)
  end

  defp format_single(package, {:ok, %{embedded: e, skipped: s} = result}) do
    note = if result[:note], do: " (#{result.note})", else: ""
    "# Embedded: #{package}\n\n#{e} chunks embedded, #{s} skipped#{note}"
  end

  defp format_single(package, {:error, reason}) do
    "# Failed: #{package}\n\n#{inspect(reason)}"
  end

  defp format_all(results) do
    {successes, failures} =
      Enum.split_with(results, fn {_dep, result} -> match?({:ok, _}, result) end)

    total_embedded =
      Enum.sum(Enum.map(successes, fn {_, {:ok, r}} -> r.embedded end))

    total_skipped =
      Enum.sum(Enum.map(successes, fn {_, {:ok, r}} -> r.skipped end))

    header = "# Hex Docs Embedded\n\n**#{length(successes)} packages**, #{total_embedded} chunks embedded, #{total_skipped} skipped\n"

    details =
      Enum.map_join(successes, "\n", fn {dep, {:ok, r}} ->
        "- **#{dep}**: #{r.embedded} embedded, #{r.skipped} skipped"
      end)

    failure_section =
      if failures != [] do
        "\n\n## Failures\n\n" <>
          Enum.map_join(failures, "\n", fn {dep, {:error, reason}} ->
            "- **#{dep}**: #{inspect(reason)}"
          end)
      else
        ""
      end

    header <> "\n" <> details <> failure_section
  end

  defp text_response(content) do
    Anubis.Server.Response.tool()
    |> Anubis.Server.Response.text(content)
  end

  defp error_response(message) do
    Anubis.Server.Response.tool()
    |> Anubis.Server.Response.error(message)
  end
end
