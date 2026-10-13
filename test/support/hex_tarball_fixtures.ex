defmodule CodeMySpecTest.HexTarballFixtures do
  @moduledoc """
  Builds a real, valid hex.pm package tarball — the exact shape
  `CodeMySpec.Embeddings.HexTarball.ex_sources/1` unpacks — so reconciler
  tests exercise the real unpack path against real bytes instead of mocking
  it away. `:erl_tar.create/3` only writes to a real path (there is no
  write-to-binary mode, unlike `extract`'s `{:binary, _}` read mode), so
  this builds through two throwaway temp files and reads the result back.
  """

  @doc """
  A hex tarball containing the given `.ex` sources, keyed by their path
  within the package (e.g. `"lib/demo.ex"`).
  """
  @spec build(%{String.t() => String.t()}) :: binary()
  def build(ex_sources) do
    contents_path = Path.join(CodeMySpec.TempFile.owned_dir("test"), "file")
    outer_path = Path.join(CodeMySpec.TempFile.owned_dir("test"), "file")

    inner_entries =
      for {path, content} <- ex_sources, do: {String.to_charlist(path), content}

    :ok = :erl_tar.create(contents_path, inner_entries, [:compressed])
    contents_gz = File.read!(contents_path)

    outer_entries = [
      {~c"VERSION", "3"},
      {~c"CHECKSUM", "test-fixture"},
      {~c"metadata.config", "{}."},
      {~c"contents.tar.gz", contents_gz}
    ]

    :ok = :erl_tar.create(outer_path, outer_entries, [])
    File.read!(outer_path)
  end

  @doc "The checksum `project_dependencies.checksum`/the lock itself would carry for this tarball."
  @spec checksum(binary()) :: String.t()
  def checksum(tarball) when is_binary(tarball) do
    :crypto.hash(:sha256, tarball) |> Base.encode16(case: :upper)
  end
end
