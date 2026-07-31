defmodule CodeMySpec.Embeddings.HexDocProjectorTest do
  use ExUnit.Case, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Dependencies
  alias CodeMySpec.Embeddings.HexDocProjector
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Projects
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "project_package/3" do
    test "writes module markdown for an installed package" do
      {scope, tmp_dir} = setup_project()

      write_dep_source(tmp_dir, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "Phoenix is a productive web framework that does not compromise speed."
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      target_path = Path.join([tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"])
      assert File.exists?(target_path), "Expected projected markdown at #{target_path}"

      markdown = File.read!(target_path)
      assert markdown =~ "# Phoenix"
      assert markdown =~ "productive web framework"
    end

    test "writes one markdown file per module, named by the module" do
      {scope, tmp_dir} = setup_project()

      write_dep_source(tmp_dir, "phoenix", "endpoint.ex", """
      defmodule Phoenix.Endpoint do
        @moduledoc "Phoenix endpoint module."
      end
      """)

      write_dep_source(tmp_dir, "phoenix", "router.ex", """
      defmodule Phoenix.Router do
        @moduledoc "Phoenix router DSL."
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      base = Path.join(tmp_dir, ".code_my_spec/hex_docs/phoenix")
      assert File.exists?(Path.join(base, "Phoenix.Endpoint.md"))
      assert File.exists?(Path.join(base, "Phoenix.Router.md"))
    end

    test "nested modules get fully-qualified names" do
      {scope, tmp_dir} = setup_project()

      write_dep_source(tmp_dir, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "Top-level Phoenix."

        defmodule Token do
          @moduledoc "Nested token helper."
        end
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      base = Path.join(tmp_dir, ".code_my_spec/hex_docs/phoenix")
      assert File.exists?(Path.join(base, "Phoenix.md"))

      nested = Path.join(base, "Phoenix.Token.md")
      assert File.exists?(nested)
      assert File.read!(nested) =~ "# Phoenix.Token"
      assert File.read!(nested) =~ "Nested token helper"
    end

    test "renders @doc'd public functions as ## fun/arity sections" do
      {scope, tmp_dir} = setup_project()

      write_dep_source(tmp_dir, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "Phoenix module."

        @doc "Starts the endpoint with opts."
        def start(opts), do: opts

        @doc "Returns a child spec."
        def child_spec, do: :ok

        @doc "Handles an integer."
        def handle(x) when is_integer(x), do: x
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      md = File.read!(Path.join([tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"]))
      assert md =~ "## start/1"
      assert md =~ "Starts the endpoint with opts."
      assert md =~ "## child_spec/0"
      assert md =~ "## handle/1", "expected `when` guard to be unwrapped to arity 1"
    end

    test "@doc on a private def does not render (and is not mis-attached)" do
      {scope, tmp_dir} = setup_project()

      write_dep_source(tmp_dir, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "Phoenix module."

        @doc "this doc sits above a private function"
        defp secret(x), do: x

        def public(x), do: x
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      md = File.read!(Path.join([tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"]))
      assert md =~ "# Phoenix"
      refute md =~ "##", "expected no function sections — the @doc was on a private def"
      refute md =~ "secret"
    end

    test "skips a module with @moduledoc false" do
      {scope, tmp_dir} = setup_project()

      write_dep_source(tmp_dir, "phoenix", "secret.ex", """
      defmodule Phoenix.Secret do
        @moduledoc false
        def x, do: 1
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      refute File.exists?(
               Path.join([tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.Secret.md"])
             )
    end

    test "skips a module with no docs at all" do
      {scope, tmp_dir} = setup_project()

      write_dep_source(tmp_dir, "phoenix", "bare.ex", """
      defmodule Phoenix.Bare do
        def x, do: 1
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      refute File.exists?(Path.join([tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.Bare.md"]))
    end

    test "drops a package's projected markdown when deps/<pkg> no longer exists" do
      {scope, tmp_dir} = setup_project()

      write_dep_source(tmp_dir, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "Phoenix v1."
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      target_path = Path.join([tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"])
      assert File.exists?(target_path)

      # Simulate uninstall: remove the package's source tree.
      File.rm_rf!(Path.join([tmp_dir, "deps/phoenix"]))

      :ok = HexDocProjector.project_package(scope, "phoenix")

      refute File.exists?(target_path),
             "Expected projected markdown to be dropped after package uninstall"
    end

    test "drops orphan modules when a package is upgraded and sheds modules" do
      {scope, tmp_dir} = setup_project()

      write_dep_source(tmp_dir, "phoenix", "a.ex", """
      defmodule Phoenix.A do
        @moduledoc "v1 module A."
      end
      """)

      write_dep_source(tmp_dir, "phoenix", "b.ex", """
      defmodule Phoenix.B do
        @moduledoc "v1 module B."
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      base = Path.join(tmp_dir, ".code_my_spec/hex_docs/phoenix")
      assert File.exists?(Path.join(base, "Phoenix.A.md"))
      assert File.exists?(Path.join(base, "Phoenix.B.md"))

      # v2: module B is gone from source.
      File.rm!(Path.join([tmp_dir, "deps/phoenix/lib/b.ex"]))

      :ok = HexDocProjector.project_package(scope, "phoenix")

      assert File.exists?(Path.join(base, "Phoenix.A.md"))

      refute File.exists?(Path.join(base, "Phoenix.B.md")),
             "Expected Phoenix.B markdown to be dropped after its source was removed"
    end
  end

  describe "resilience to unparseable / non-literal source" do
    test "a syntactically invalid file is skipped without aborting sibling modules" do
      {scope, tmp_dir} = setup_project()

      write_dep_source(tmp_dir, "phoenix", "good.ex", """
      defmodule Phoenix.Good do
        @moduledoc "Good module."
      end
      """)

      # Garbage that Code.string_to_quoted/1 rejects.
      write_dep_source(tmp_dir, "phoenix", "bad.ex", """
      defmodule Phoenix.Bad do
        @moduledoc "oops
        def (((
      """)

      # Must not raise — this is the root-cause regression (a single bad
      # source file used to take down the whole projection via a raise).
      assert :ok = HexDocProjector.project_package(scope, "phoenix")

      base = Path.join(tmp_dir, ".code_my_spec/hex_docs/phoenix")

      assert File.exists?(Path.join(base, "Phoenix.Good.md")),
             "expected the valid sibling module to still project"
    end

    test "a non-literal @moduledoc is skipped without crashing" do
      {scope, tmp_dir} = setup_project()

      write_dep_source(tmp_dir, "phoenix", "dyn.ex", """
      defmodule Phoenix.Dyn do
        @moduledoc File.read!("README.md")

        @doc "still documented"
        def f(opts), do: opts
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      # The module still projects (it has a function doc), but the
      # non-literal moduledoc expression is not captured.
      target = Path.join([tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.Dyn.md"])
      assert File.exists?(target)
      md = File.read!(target)
      assert md =~ "## f/1"
      refute md =~ "File.read!"
    end
  end

  describe "content-aware writes" do
    test "skips re-writing markdown when content matches the existing file" do
      {scope, tmp_dir} = setup_project()

      write_dep_source(tmp_dir, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "Phoenix is the productive web framework."
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      target = Path.join([tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"])
      first_mtime = File.stat!(target, time: :posix).mtime

      # Guarantee at least 1s of clock movement so a fresh write would
      # visibly bump the mtime.
      Process.sleep(1_100)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      second_mtime = File.stat!(target, time: :posix).mtime

      assert second_mtime == first_mtime,
             "expected the projector to skip the write when content is unchanged"
    end

    test "writes when the on-disk content differs from the rendered markdown" do
      {scope, tmp_dir} = setup_project()

      write_dep_source(tmp_dir, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "v1 docs"
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      target = Path.join([tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"])
      assert File.read!(target) =~ "v1 docs"

      # Externally clobber the projected file with stale content so the
      # projector's needs_write? check has something to disagree with.
      File.write!(target, "stale content that does not match")

      :ok = HexDocProjector.project_package(scope, "phoenix")

      assert File.read!(target) =~ "v1 docs",
             "expected the projector to overwrite stale content with the rendered markdown"
    end
  end

  describe "project/1" do
    test "projects every installed package and drops markdown for uninstalled packages" do
      {scope, tmp_dir} = setup_project()

      write_dep_source(tmp_dir, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "Phoenix doc."
      end
      """)

      write_dep_source(tmp_dir, "ecto", "ecto.ex", """
      defmodule Ecto do
        @moduledoc "Ecto doc."
      end
      """)

      :ok = HexDocProjector.project(scope)

      assert File.exists?(Path.join(tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"))
      assert File.exists?(Path.join(tmp_dir, ".code_my_spec/hex_docs/ecto/Ecto.md"))

      # Uninstall ecto and re-project — its markdown should disappear.
      File.rm_rf!(Path.join([tmp_dir, "deps/ecto"]))
      :ok = HexDocProjector.project(scope)

      assert File.exists?(Path.join(tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"))
      refute File.exists?(Path.join(tmp_dir, ".code_my_spec/hex_docs/ecto/Ecto.md"))
    end

    test "is a no-op when `deps/` does not exist" do
      {scope, _tmp_dir} = setup_project()

      assert :ok = HexDocProjector.project(scope)
    end
  end

  # -- Helpers --

  describe "project_pending/2 — convergence instead of a settle timer" do
    # The race this replaced, staged directly: the lock is complete, the unpack
    # is not. The old design waited ten seconds and then read whatever was
    # there; this one projects what has landed and reports what has not.
    test "projects what has landed and reports what has not" do
      {scope, tmp_dir} = setup_project()

      {:ok, _} = Dependencies.record_lockfile(scope, lock(["phoenix", "ecto"]))

      # Only phoenix has finished unpacking.
      write_dep_source(tmp_dir, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "A productive web framework."
      end
      """)

      assert %{projected: ["phoenix"], missing: ["ecto"]} =
               HexDocProjector.project_pending(scope)

      assert File.exists?(Path.join([tmp_dir, ".code_my_spec/hex_docs/phoenix/Phoenix.md"]))
    end

    # The end state the timer never had: something a caller can wait for.
    test "a second pass after the unpack finishes converges" do
      {scope, tmp_dir} = setup_project()

      {:ok, _} = Dependencies.record_lockfile(scope, lock(["phoenix", "ecto"]))

      write_dep_source(
        tmp_dir,
        "phoenix",
        "phoenix.ex",
        ~s|defmodule Phoenix do\n@moduledoc "P"\nend|
      )

      assert %{missing: ["ecto"]} = HexDocProjector.project_pending(scope)

      write_dep_source(tmp_dir, "ecto", "ecto.ex", ~s|defmodule Ecto do\n@moduledoc "E"\nend|)

      assert %{projected: ["ecto"], missing: []} = HexDocProjector.project_pending(scope)
      assert Dependencies.pending(scope) == []
    end

    test "an already-projected package is not projected again" do
      {scope, tmp_dir} = setup_project()

      {:ok, _} = Dependencies.record_lockfile(scope, lock(["phoenix"]))

      write_dep_source(
        tmp_dir,
        "phoenix",
        "phoenix.ex",
        ~s|defmodule Phoenix do\n@moduledoc "P"\nend|
      )

      assert %{projected: ["phoenix"]} = HexDocProjector.project_pending(scope)
      assert %{projected: [], missing: []} = HexDocProjector.project_pending(scope)
    end

    # Bounded retries have to end somewhere, and where they end must be
    # "we looked and found nothing", never "nothing needed doing".
    test "settle_missing names what never appeared and converges the project" do
      {scope, _tmp_dir} = setup_project()

      {:ok, _} = Dependencies.record_lockfile(scope, lock(["never_fetched"]))

      assert ["never_fetched"] = HexDocProjector.settle_missing(scope)
      assert Dependencies.pending(scope) == []
    end
  end

  defp lock(names) do
    body =
      Enum.map_join(names, ",\n", fn name ->
        ~s(  "#{name}": {:hex, :#{name}, "1.0.0", "chk", [:mix], [], "hexpm", "chk2"})
      end)

    "%{\n" <> body <> "\n}\n"
  end

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

  # Write a dependency's Elixir source under
  # `<tmp_dir>/deps/<package>/lib/<rel_path>`. The presence of
  # `deps/<package>` is what marks it as a projectable dependency
  # (the user's own app never lives under `deps/`).
  defp write_dep_source(tmp_dir, package, rel_path, source) do
    path = Path.join([tmp_dir, "deps", package, "lib", rel_path])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    path
  end
end
