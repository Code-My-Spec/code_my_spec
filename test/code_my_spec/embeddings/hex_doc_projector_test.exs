defmodule CodeMySpec.Embeddings.HexDocProjectorTest do
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Dependencies
  alias CodeMySpec.Embeddings.HexDocProjector
  alias CodeMySpec.Environments
  alias CodeMySpec.Projects
  alias CodeMySpec.Support.InMemoryEnvironment
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "project_package/3" do
    test "writes module markdown for an installed package" do
      {scope, env} = setup_project()

      write_dep_source(env, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "Phoenix is a productive web framework that does not compromise speed."
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      target_path = Path.join([".code_my_spec/hex_docs/phoenix/Phoenix.md"])

      assert Environments.file_exists?(env, target_path),
             "Expected projected markdown at #{target_path}"

      markdown = read_env!(env, target_path)
      assert markdown =~ "# Phoenix"
      assert markdown =~ "productive web framework"
    end

    test "writes one markdown file per module, named by the module" do
      {scope, env} = setup_project()

      write_dep_source(env, "phoenix", "endpoint.ex", """
      defmodule Phoenix.Endpoint do
        @moduledoc "Phoenix endpoint module."
      end
      """)

      write_dep_source(env, "phoenix", "router.ex", """
      defmodule Phoenix.Router do
        @moduledoc "Phoenix router DSL."
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      base = ".code_my_spec/hex_docs/phoenix"
      assert Environments.file_exists?(env, Path.join(base, "Phoenix.Endpoint.md"))
      assert Environments.file_exists?(env, Path.join(base, "Phoenix.Router.md"))
    end

    test "nested modules get fully-qualified names" do
      {scope, env} = setup_project()

      write_dep_source(env, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "Top-level Phoenix."

        defmodule Token do
          @moduledoc "Nested token helper."
        end
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      base = ".code_my_spec/hex_docs/phoenix"
      assert Environments.file_exists?(env, Path.join(base, "Phoenix.md"))

      nested = Path.join(base, "Phoenix.Token.md")
      assert Environments.file_exists?(env, nested)
      assert read_env!(env, nested) =~ "# Phoenix.Token"
      assert read_env!(env, nested) =~ "Nested token helper"
    end

    test "renders @doc'd public functions as ## fun/arity sections" do
      {scope, env} = setup_project()

      write_dep_source(env, "phoenix", "phoenix.ex", """
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

      md = read_env!(env, Path.join([".code_my_spec/hex_docs/phoenix/Phoenix.md"]))
      assert md =~ "## start/1"
      assert md =~ "Starts the endpoint with opts."
      assert md =~ "## child_spec/0"
      assert md =~ "## handle/1", "expected `when` guard to be unwrapped to arity 1"
    end

    test "@doc on a private def does not render (and is not mis-attached)" do
      {scope, env} = setup_project()

      write_dep_source(env, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "Phoenix module."

        @doc "this doc sits above a private function"
        defp secret(x), do: x

        def public(x), do: x
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      md = read_env!(env, Path.join([".code_my_spec/hex_docs/phoenix/Phoenix.md"]))
      assert md =~ "# Phoenix"
      refute md =~ "##", "expected no function sections — the @doc was on a private def"
      refute md =~ "secret"
    end

    test "skips a module with @moduledoc false" do
      {scope, env} = setup_project()

      write_dep_source(env, "phoenix", "secret.ex", """
      defmodule Phoenix.Secret do
        @moduledoc false
        def x, do: 1
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      refute Environments.file_exists?(
               env,
               Path.join([".code_my_spec/hex_docs/phoenix/Phoenix.Secret.md"])
             )
    end

    test "skips a module with no docs at all" do
      {scope, env} = setup_project()

      write_dep_source(env, "phoenix", "bare.ex", """
      defmodule Phoenix.Bare do
        def x, do: 1
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      refute Environments.file_exists?(
               env,
               Path.join([".code_my_spec/hex_docs/phoenix/Phoenix.Bare.md"])
             )
    end

    test "drops a package's projected markdown when deps/<pkg> no longer exists" do
      {scope, env} = setup_project()

      write_dep_source(env, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "Phoenix v1."
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      target_path = Path.join([".code_my_spec/hex_docs/phoenix/Phoenix.md"])
      assert Environments.file_exists?(env, target_path)

      # Simulate uninstall: remove the package's source tree.
      rm_rf_env!(env, "deps/phoenix")

      :ok = HexDocProjector.project_package(scope, "phoenix")

      refute Environments.file_exists?(env, target_path),
             "Expected projected markdown to be dropped after package uninstall"
    end

    test "drops orphan modules when a package is upgraded and sheds modules" do
      {scope, env} = setup_project()

      write_dep_source(env, "phoenix", "a.ex", """
      defmodule Phoenix.A do
        @moduledoc "v1 module A."
      end
      """)

      write_dep_source(env, "phoenix", "b.ex", """
      defmodule Phoenix.B do
        @moduledoc "v1 module B."
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      base = ".code_my_spec/hex_docs/phoenix"
      assert Environments.file_exists?(env, Path.join(base, "Phoenix.A.md"))
      assert Environments.file_exists?(env, Path.join(base, "Phoenix.B.md"))

      # v2: module B is gone from source.
      :ok = Environments.delete_file(env, "deps/phoenix/lib/b.ex")

      :ok = HexDocProjector.project_package(scope, "phoenix")

      assert Environments.file_exists?(env, Path.join(base, "Phoenix.A.md"))

      refute Environments.file_exists?(env, Path.join(base, "Phoenix.B.md")),
             "Expected Phoenix.B markdown to be dropped after its source was removed"
    end
  end

  describe "resilience to unparseable / non-literal source" do
    test "a syntactically invalid file is skipped without aborting sibling modules" do
      {scope, env} = setup_project()

      write_dep_source(env, "phoenix", "good.ex", """
      defmodule Phoenix.Good do
        @moduledoc "Good module."
      end
      """)

      # Garbage that Code.string_to_quoted/1 rejects.
      write_dep_source(env, "phoenix", "bad.ex", """
      defmodule Phoenix.Bad do
        @moduledoc "oops
        def (((
      """)

      # Must not raise — this is the root-cause regression (a single bad
      # source file used to take down the whole projection via a raise).
      assert :ok = HexDocProjector.project_package(scope, "phoenix")

      base = ".code_my_spec/hex_docs/phoenix"

      assert Environments.file_exists?(env, Path.join(base, "Phoenix.Good.md")),
             "expected the valid sibling module to still project"
    end

    test "a non-literal @moduledoc is skipped without crashing" do
      {scope, env} = setup_project()

      write_dep_source(env, "phoenix", "dyn.ex", """
      defmodule Phoenix.Dyn do
        @moduledoc read_env!(env, "README.md")

        @doc "still documented"
        def f(opts), do: opts
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      # The module still projects (it has a function doc), but the
      # non-literal moduledoc expression is not captured.
      target = Path.join([".code_my_spec/hex_docs/phoenix/Phoenix.Dyn.md"])
      assert Environments.file_exists?(env, target)
      md = read_env!(env, target)
      assert md =~ "## f/1"
      refute md =~ "File.read!"
    end
  end

  describe "content-aware writes" do
    test "skips re-writing markdown when content matches the existing file" do
      {scope, env} = setup_project()

      write_dep_source(env, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "Phoenix is the productive web framework."
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      target = Path.join([".code_my_spec/hex_docs/phoenix/Phoenix.md"])
      {:ok, %{mtime: first_mtime}} = Environments.stat(env, target)

      # Guarantee at least 1s of clock movement so a fresh write would
      # visibly bump the mtime.
      Process.sleep(1_100)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      {:ok, %{mtime: second_mtime}} = Environments.stat(env, target)

      assert second_mtime == first_mtime,
             "expected the projector to skip the write when content is unchanged"
    end

    test "writes when the on-disk content differs from the rendered markdown" do
      {scope, env} = setup_project()

      write_dep_source(env, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "v1 docs"
      end
      """)

      :ok = HexDocProjector.project_package(scope, "phoenix")

      target = Path.join([".code_my_spec/hex_docs/phoenix/Phoenix.md"])
      assert read_env!(env, target) =~ "v1 docs"

      # Externally clobber the projected file with stale content so the
      # projector's needs_write? check has something to disagree with.
      :ok = Environments.write_file(env, target, "stale content that does not match")

      :ok = HexDocProjector.project_package(scope, "phoenix")

      assert read_env!(env, target) =~ "v1 docs",
             "expected the projector to overwrite stale content with the rendered markdown"
    end
  end

  describe "project/1" do
    test "projects every installed package and drops markdown for uninstalled packages" do
      {scope, env} = setup_project()

      write_dep_source(env, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "Phoenix doc."
      end
      """)

      write_dep_source(env, "ecto", "ecto.ex", """
      defmodule Ecto do
        @moduledoc "Ecto doc."
      end
      """)

      :ok = HexDocProjector.project(scope)

      assert Environments.file_exists?(env, ".code_my_spec/hex_docs/phoenix/Phoenix.md")
      assert Environments.file_exists?(env, ".code_my_spec/hex_docs/ecto/Ecto.md")

      # Uninstall ecto and re-project — its markdown should disappear.
      rm_rf_env!(env, "deps/ecto")
      :ok = HexDocProjector.project(scope)

      assert Environments.file_exists?(env, ".code_my_spec/hex_docs/phoenix/Phoenix.md")
      refute Environments.file_exists?(env, ".code_my_spec/hex_docs/ecto/Ecto.md")
    end

    test "is a no-op when `deps/` does not exist" do
      {scope, _env} = setup_project()

      assert :ok = HexDocProjector.project(scope)
    end
  end

  # -- Helpers --

  describe "project_pending/2 — convergence instead of a settle timer" do
    # The race this replaced, staged directly: the lock is complete, the unpack
    # is not. The old design waited ten seconds and then read whatever was
    # there; this one projects what has landed and reports what has not.
    test "projects what has landed and reports what has not" do
      {scope, env} = setup_project()

      {:ok, _} = Dependencies.record_lockfile(scope, lock(["phoenix", "ecto"]))

      # Only phoenix has finished unpacking.
      write_dep_source(env, "phoenix", "phoenix.ex", """
      defmodule Phoenix do
        @moduledoc "A productive web framework."
      end
      """)

      assert %{projected: ["phoenix"], missing: ["ecto"]} =
               HexDocProjector.project_pending(scope)

      assert Environments.file_exists?(
               env,
               Path.join([".code_my_spec/hex_docs/phoenix/Phoenix.md"])
             )
    end

    # The end state the timer never had: something a caller can wait for.
    test "a second pass after the unpack finishes converges" do
      {scope, env} = setup_project()

      {:ok, _} = Dependencies.record_lockfile(scope, lock(["phoenix", "ecto"]))

      write_dep_source(
        env,
        "phoenix",
        "phoenix.ex",
        ~s|defmodule Phoenix do\n@moduledoc "P"\nend|
      )

      assert %{missing: ["ecto"]} = HexDocProjector.project_pending(scope)

      write_dep_source(env, "ecto", "ecto.ex", ~s|defmodule Ecto do\n@moduledoc "E"\nend|)

      assert %{projected: ["ecto"], missing: []} = HexDocProjector.project_pending(scope)
      assert Dependencies.pending(scope) == []
    end

    test "an already-projected package is not projected again" do
      {scope, env} = setup_project()

      {:ok, _} = Dependencies.record_lockfile(scope, lock(["phoenix"]))

      write_dep_source(
        env,
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
      {scope, _env} = setup_project()

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
    {:ok, env} = InMemoryEnvironment.create()
    on_exit(fn -> InMemoryEnvironment.destroy(env) end)

    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: env.cwd})

    scope = %{scope | active_project: project, cwd: env.cwd, environment: env}

    {scope, env}
  end

  # Write a dependency's Elixir source under
  # `deps/<package>/lib/<rel_path>` in the environment. The presence of
  # `deps/<package>` is what marks it as a projectable dependency
  # (the user's own app never lives under `deps/`).
  defp write_dep_source(env, package, rel_path, source) do
    path = Path.join(["deps", package, "lib", rel_path])
    :ok = Environments.write_file(env, path, source)
    path
  end

  # Read through the environment the code under test writes to. `File.read!`
  # here would be asserting against a disk that is no longer involved.
  defp read_env!(env, path) do
    {:ok, contents} = Environments.read_file(env, path)
    contents
  end

  # Remove a whole subtree. The map is keyed by file path, so "a directory" is
  # every key under that prefix — which is also why an emptied directory stops
  # existing, exactly as `File.rm_rf!` leaves it.
  defp rm_rf_env!(env, dir) do
    env
    |> Environments.glob(Path.join(dir, "**/*"))
    |> Enum.each(&Environments.delete_file(env, &1))

    :ok
  end
end
