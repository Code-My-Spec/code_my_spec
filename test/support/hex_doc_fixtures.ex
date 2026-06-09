defmodule CodeMySpecSpex.HexDocFixtures do
  @moduledoc """
  Helpers for spec scenarios that need real dependency source sitting
  under `<stub_cwd>/deps/<package>/lib/` for the hex doc projector to
  read.

  Hex doc projection reads `@moduledoc`/`@doc` directly from dependency
  source (`deps/<package>/lib/**/*.ex`), so spex that exercise the
  projector → FileSync → Embeddings chain just need to drop a real `.ex`
  file on disk. No compilation, no BEAMs, no OTP coupling.
  """

  @doc """
  Install a fixture dependency module under
  `cwd/deps/<package>/lib/<module>.ex` whose `@moduledoc` is `docstring`.

  `module` is the fully-qualified Elixir module name (e.g.
  `"Phoenix.Endpoint"`) — it's both the `defmodule` name and the label
  the projector uses to name the markdown file (`<module>.md`).

  Returns the absolute source path.
  """
  def install_source(cwd, package, module, docstring)
      when is_binary(cwd) and is_binary(package) and is_binary(module) and is_binary(docstring) do
    filename = module |> String.replace(".", "_") |> Macro.underscore()

    source_path =
      Path.join([cwd, "deps", package, "lib", "#{filename}.ex"])

    File.mkdir_p!(Path.dirname(source_path))

    source = """
    defmodule #{module} do
      @moduledoc #{inspect(docstring)}
    end
    """

    File.write!(source_path, source)

    source_path
  end

  @doc """
  Remove an installed fixture dependency (simulates uninstall by
  deleting the package's source tree from `deps/`).
  """
  def uninstall_package(cwd, package) when is_binary(cwd) and is_binary(package) do
    pkg_dir = Path.join([cwd, "deps", package])
    File.rm_rf!(pkg_dir)
    :ok
  end
end
