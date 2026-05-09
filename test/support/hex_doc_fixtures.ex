defmodule CodeMySpecSpex.HexDocFixtures do
  @moduledoc """
  Helpers for spec scenarios that need real compiled BEAM files with
  EEP-48 docs sitting under `<stub_cwd>/_build/dev/lib/<package>/ebin/`.

  Hex doc projection reads real BEAMs from real disk (BEAMs aren't a
  memfs concept), so spex that exercise the projector → FileSync →
  Embeddings chain need to produce real BEAM files. This module
  compiles tiny fixture modules at test time and writes their binary
  output to the stub working directory so the projector can find
  them on the next sync click.
  """

  @doc """
  Install a fixture BEAM under `cwd/_build/dev/lib/<package>/ebin/Elixir.<module_filename>.beam`
  whose embedded `@moduledoc` is `docstring`.

  The actual Elixir module name inside the BEAM is unique per call
  (so re-installing doesn't collide with prior compilations), but the
  *filename* is what the projector uses to derive the module label
  in markdown — that's `module_filename`.

  Returns the absolute beam path.
  """
  def install_beam(cwd, package, module_filename, docstring)
      when is_binary(cwd) and is_binary(package) and is_binary(module_filename) and
             is_binary(docstring) do
    beam_path =
      Path.join([cwd, "_build/dev/lib", package, "ebin", "Elixir.#{module_filename}.beam"])

    File.mkdir_p!(Path.dirname(beam_path))

    source = """
    defmodule TestHexDocFixture#{System.unique_integer([:positive])} do
      @moduledoc #{inspect(docstring)}
    end
    """

    [{_mod, binary}] = Code.compile_string(source)
    File.write!(beam_path, binary)

    beam_path
  end

  @doc """
  Remove an installed fixture BEAM (simulates uninstall by deleting
  the package's compiled artifacts from `_build`).
  """
  def uninstall_package(cwd, package) when is_binary(cwd) and is_binary(package) do
    pkg_dir = Path.join([cwd, "_build/dev/lib", package])
    File.rm_rf!(pkg_dir)
    :ok
  end
end
