defmodule CodeMySpec.Embeddings.HexDocProjectorTest do
  # async: false because we toggle the global `Code.put_compiler_option(:docs)`
  # to keep EEP-48 docs in the fixture BEAMs (mix test strips them by default).
  # Concurrent flips would race.
  use ExUnit.Case, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Embeddings.HexDocProjector
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Projects
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "project_package/2" do
    test "writes module markdown for an installed package" do
      {scope, tmp_dir} = setup_project()

      install_fixture_beam(tmp_dir, "phoenix", "Phoenix",
        "Phoenix is a productive web framework that does not compromise speed or maintainability.")

      :ok = HexDocProjector.project_package(scope, "phoenix")

      target_path = Path.join([tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"])
      assert File.exists?(target_path), "Expected projected markdown at #{target_path}"

      markdown = File.read!(target_path)
      assert markdown =~ "# Phoenix"
      assert markdown =~ "productive web framework"
    end

    test "writes one markdown file per beam in the package" do
      {scope, tmp_dir} = setup_project()

      install_fixture_beam(tmp_dir, "phoenix", "Phoenix.Endpoint", "Phoenix endpoint module.")
      install_fixture_beam(tmp_dir, "phoenix", "Phoenix.Router", "Phoenix router DSL.")

      :ok = HexDocProjector.project_package(scope, "phoenix")

      base = Path.join(tmp_dir, ".code_my_spec/hex_docs/phoenix")
      assert File.exists?(Path.join(base, "Phoenix.Endpoint.md"))
      assert File.exists?(Path.join(base, "Phoenix.Router.md"))
    end

    test "drops a package's projected markdown when the package's ebin no longer exists" do
      {scope, tmp_dir} = setup_project()

      install_fixture_beam(tmp_dir, "phoenix", "Phoenix", "Phoenix v1.")
      :ok = HexDocProjector.project_package(scope, "phoenix")

      target_path = Path.join([tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"])
      assert File.exists?(target_path)

      # Simulate uninstall: remove the package's compiled artifacts.
      File.rm_rf!(Path.join([tmp_dir, "_build/dev/lib/phoenix"]))

      :ok = HexDocProjector.project_package(scope, "phoenix")

      refute File.exists?(target_path),
             "Expected projected markdown to be dropped after package uninstall"
    end

    test "drops orphan modules when a package is upgraded and sheds modules" do
      {scope, tmp_dir} = setup_project()

      # v1: two modules
      install_fixture_beam(tmp_dir, "phoenix", "Phoenix.A", "v1 module A.")
      install_fixture_beam(tmp_dir, "phoenix", "Phoenix.B", "v1 module B.")
      :ok = HexDocProjector.project_package(scope, "phoenix")

      base = Path.join(tmp_dir, ".code_my_spec/hex_docs/phoenix")
      assert File.exists?(Path.join(base, "Phoenix.A.md"))
      assert File.exists?(Path.join(base, "Phoenix.B.md"))

      # v2: only one module remains
      File.rm!(Path.join([tmp_dir, "_build/dev/lib/phoenix/ebin/Elixir.Phoenix.B.beam"]))

      :ok = HexDocProjector.project_package(scope, "phoenix")

      assert File.exists?(Path.join(base, "Phoenix.A.md"))
      refute File.exists?(Path.join(base, "Phoenix.B.md")),
             "Expected Phoenix.B markdown to be dropped after the v2 BEAM was removed"
    end
  end

  describe "content-aware writes" do
    test "skips re-writing markdown when content matches the existing file" do
      {scope, tmp_dir} = setup_project()

      install_fixture_beam(tmp_dir, "phoenix", "Phoenix",
        "Phoenix is the productive web framework.")

      :ok = HexDocProjector.project_package(scope, "phoenix")

      target = Path.join([tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"])
      first_mtime = File.stat!(target, time: :posix).mtime

      # Must guarantee at least 1s of clock movement so a fresh
      # File.write would visibly bump the mtime.
      Process.sleep(1_100)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      second_mtime = File.stat!(target, time: :posix).mtime

      assert second_mtime == first_mtime,
             "expected the projector to skip the write when content is unchanged"
    end

    test "writes when the on-disk content differs from the rendered markdown" do
      {scope, tmp_dir} = setup_project()

      install_fixture_beam(tmp_dir, "phoenix", "Phoenix", "v1 docs")
      :ok = HexDocProjector.project_package(scope, "phoenix")

      target = Path.join([tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"])
      assert File.read!(target) =~ "v1 docs"

      # Externally clobber the projected file with stale content so
      # the projector's needs_write? check has something to disagree
      # with.
      File.write!(target, "stale content that does not match")

      :ok = HexDocProjector.project_package(scope, "phoenix")

      assert File.read!(target) =~ "v1 docs",
             "expected the projector to overwrite stale content with the rendered markdown"
    end
  end

  describe "project/1" do
    test "projects every installed package and drops markdown for uninstalled packages" do
      {scope, tmp_dir} = setup_project()

      install_fixture_beam(tmp_dir, "phoenix", "Phoenix", "Phoenix doc.")
      install_fixture_beam(tmp_dir, "ecto", "Ecto", "Ecto doc.")

      :ok = HexDocProjector.project(scope)

      assert File.exists?(Path.join(tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"))
      assert File.exists?(Path.join(tmp_dir, ".code_my_spec/hex_docs/ecto/Ecto.md"))

      # Uninstall ecto and re-project — its markdown should disappear.
      File.rm_rf!(Path.join([tmp_dir, "_build/dev/lib/ecto"]))
      :ok = HexDocProjector.project(scope)

      assert File.exists?(Path.join(tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"))
      refute File.exists?(Path.join(tmp_dir, ".code_my_spec/hex_docs/ecto/Ecto.md"))
    end

    test "is a no-op when `_build/dev/lib` does not exist" do
      {scope, _tmp_dir} = setup_project()

      assert :ok = HexDocProjector.project(scope)
    end
  end

  # -- Helpers --

  defp setup_project do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    scope = %{
      scope
      | active_project: project,
        cwd: tmp_dir,
        environment: Environment.new(:local, tmp_dir)
    }

    {scope, tmp_dir}
  end

  # Compile a fixture module with the given docstring and write its
  # BEAM into `<tmp_dir>/_build/dev/lib/<package>/ebin/Elixir.<module_filename>.beam`.
  # The actual Elixir module name (inside the BEAM) is unique per call
  # so repeated installs in the same test don't collide; the filename
  # (and thus the markdown filename produced by the projector) is what
  # the caller controls.
  defp install_fixture_beam(tmp_dir, package, module_filename, docstring) do
    beam_path =
      Path.join([tmp_dir, "_build/dev/lib", package, "ebin", "Elixir.#{module_filename}.beam"])

    File.mkdir_p!(Path.dirname(beam_path))

    # Mark the package as a real hex dep so the projector doesn't
    # skip it. Production check: `<cwd>/deps/<package>` exists for
    # hex deps but not for the user's own app.
    File.mkdir_p!(Path.join([tmp_dir, "deps", package]))

    source = """
    defmodule TestHexDocFixture#{System.unique_integer([:positive])} do
      @moduledoc #{inspect(docstring)}
    end
    """

    # `mix test` strips docs by default for compile speed, which would
    # leave the BEAM without an EEP-48 `Docs` chunk and the projector
    # with nothing to extract. Force docs on for the duration of the
    # compile.
    prior = Code.get_compiler_option(:docs)
    Code.put_compiler_option(:docs, true)

    [{_mod, binary}] =
      try do
        Code.compile_string(source)
      after
        Code.put_compiler_option(:docs, prior)
      end

    File.write!(beam_path, binary)

    beam_path
  end
end
