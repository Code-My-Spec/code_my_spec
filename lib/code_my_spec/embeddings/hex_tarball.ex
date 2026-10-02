defmodule CodeMySpec.Embeddings.HexTarball do
  @moduledoc """
  Unpacks a hex.pm package tarball in memory and returns its `.ex` sources.

  A hex tarball is a tar of `VERSION`, `CHECKSUM`, `metadata.config` and
  `contents.tar.gz` — the package's actual source, gzipped again inside the
  outer tar. Nothing here touches disk: `:erl_tar`'s `:memory` mode and
  `:zlib` do both unpacks as pure binary transforms, which is what keeps the
  reconciler's fetch-parse-chunk-embed sequence free of a working tree.
  """

  @doc """
  `.ex` file contents under `lib/`, keyed by their path within the package.

  `{:error, reason}` for a tarball that isn't the shape hex.pm promises —
  the reconciler records that as a failed package rather than crashing the
  FLAME call outright.
  """
  @spec ex_sources(binary()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def ex_sources(tarball) when is_binary(tarball) do
    with {:ok, outer} <- extract(tarball),
         {:ok, contents_gz} <- fetch_entry(outer, ~c"contents.tar.gz"),
         {:ok, inner} <- gunzip_extract(contents_gz) do
      {:ok, filter_ex_sources(inner)}
    end
  end

  defp extract(tarball) do
    case :erl_tar.extract({:binary, tarball}, [:memory]) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, {:outer_tar, reason}}
    end
  end

  defp gunzip_extract(gz) do
    case :erl_tar.extract({:binary, :zlib.gunzip(gz)}, [:memory]) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, {:inner_tar, reason}}
    end
  rescue
    e -> {:error, {:gunzip, e}}
  end

  defp fetch_entry(entries, name) do
    case List.keyfind(entries, name, 0) do
      {_name, content} -> {:ok, content}
      nil -> {:error, {:missing_entry, name}}
    end
  end

  defp filter_ex_sources(entries) do
    for {name_charlist, content} <- entries,
        path = List.to_string(name_charlist),
        String.starts_with?(path, "lib/"),
        String.ends_with?(path, ".ex"),
        into: %{},
        do: {path, content}
  end
end
