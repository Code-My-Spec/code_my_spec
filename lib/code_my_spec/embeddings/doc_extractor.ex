defmodule CodeMySpec.Embeddings.DocExtractor do
  @moduledoc """
  Extracts documentation from compiled BEAM files in _build/.

  Uses EEP-48 documentation chunks embedded in every compiled Elixir module.
  Returns clean markdown — no network access, no HTML parsing.
  """

  @doc """
  Extract docs for a single dependency from its compiled beam files.

  Returns a list of `%{module: atom, markdown: String.t()}` maps.
  """
  def extract(build_dir, app_name) do
    ebin = Path.join([build_dir, "lib", to_string(app_name), "ebin"])

    if not File.dir?(ebin) do
      {:error, "Not found: #{ebin}. Is the dependency compiled?"}
    else
      docs =
        ebin
        |> Path.join("*.beam")
        |> Path.wildcard()
        |> Enum.flat_map(&extract_beam/1)
        |> Enum.reject(fn %{markdown: md} -> md == "" end)

      {:ok, docs}
    end
  end

  @doc """
  List all compiled dependencies in a build directory.
  """
  def list_deps(build_dir) do
    lib_dir = Path.join(build_dir, "lib")

    if File.dir?(lib_dir) do
      lib_dir
      |> File.ls!()
      |> Enum.filter(fn name ->
        Path.join([lib_dir, name, "ebin"]) |> File.dir?()
      end)
      |> Enum.sort()
    else
      []
    end
  end

  @doc """
  Extract and render docs for a dep as a single markdown string suitable for embedding.
  """
  def extract_as_markdown(build_dir, app_name) do
    case extract(build_dir, app_name) do
      {:ok, docs} ->
        markdown =
          docs
          |> Enum.sort_by(& &1.module)
          |> Enum.map_join("\n\n---\n\n", & &1.markdown)

        {:ok, markdown}

      error ->
        error
    end
  end

  # -- Private --

  defp extract_beam(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, {mod, [{~c"Docs", docs_bin}]}} <- :beam_lib.chunks(binary, [~c"Docs"]),
         {:docs_v1, _anno, _lang, format, mod_doc, _meta, func_docs} <-
           :erlang.binary_to_term(docs_bin) do
      if format == "text/markdown" do
        [%{module: mod, markdown: render_module(mod, mod_doc, func_docs)}]
      else
        []
      end
    else
      _ -> []
    end
  end

  defp render_module(mod, mod_doc, func_docs) do
    header = "# #{inspect(mod)}\n\n#{extract_text(mod_doc)}\n"

    functions =
      func_docs
      |> Enum.filter(fn {_id, _anno, _sigs, doc, _meta} -> has_doc?(doc) end)
      |> Enum.map_join("\n", fn {{kind, name, arity}, _anno, signatures, doc, _meta} ->
        sig = format_signature(kind, name, arity, signatures)
        "## #{sig}\n\n#{extract_text(doc)}\n"
      end)

    String.trim(header <> "\n" <> functions)
  end

  defp extract_text(%{"en" => text}), do: String.trim(text)
  defp extract_text(_), do: ""

  defp has_doc?(%{"en" => _}), do: true
  defp has_doc?(_), do: false

  defp format_signature(_kind, _name, _arity, [sig | _]) when is_binary(sig), do: sig
  defp format_signature(_kind, name, arity, _), do: "#{name}/#{arity}"
end
