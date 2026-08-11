defmodule CodeMySpec.Support.InMemoryEnvironmentTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Support.InMemoryEnvironment

  describe "create/1 and destroy/1" do
    test "create returns an Environment with an Agent in ref" do
      {:ok, env} = InMemoryEnvironment.create()

      assert %Environment{type: :memory, ref: %{agent: agent}} = env
      assert is_pid(agent)
      assert Process.alive?(agent)

      :ok = InMemoryEnvironment.destroy(env)
    end

    test "create honors :working_dir" do
      {:ok, env} = InMemoryEnvironment.create(working_dir: "/tmp/proj")
      assert env.cwd == "/tmp/proj"
      :ok = InMemoryEnvironment.destroy(env)
    end

    test "destroy stops the Agent" do
      {:ok, env} = InMemoryEnvironment.create()
      agent = env.ref.agent

      :ok = InMemoryEnvironment.destroy(env)
      refute Process.alive?(agent)
    end

    # The race the old implementation lost. It asked `Process.alive?/1` and then
    # called `Agent.stop/1`, and the gap between the two is reachable by
    # construction: the agent is `start_link`ed from the test process, while
    # `destroy/1` runs from `on_exit` in a different process after that one has
    # exited — so the link is killing the agent exactly when destroy looks at
    # it. Winning the check and losing the stop produced
    #
    #     ** (exit) exited in: GenServer.stop(#PID<...>, :normal, :infinity)
    #
    # reported against whichever test was running. It needs a loaded box, which
    # is why the file passes forty times in isolation and fails under the
    # analyzer.
    #
    # Several destroys at once is the closest deterministic stand-in: only one
    # can be the kill that lands, and the others meet a process that is dying or
    # gone.
    test "concurrent destroys all answer, none exits" do
      {:ok, env} = InMemoryEnvironment.create()

      results =
        1..20
        |> Task.async_stream(fn _ -> InMemoryEnvironment.destroy(env) end,
          max_concurrency: 20,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(&1 == :ok))
      refute Process.alive?(env.ref.agent)
    end

    # Destroying from a process that never owned it, which is what `on_exit`
    # does. The old version's `Agent.stop/1` would have been fine here and the
    # kill must be too — in particular it must not need the link it does not
    # have.
    test "destroy works from a process that did not create it" do
      {:ok, env} = InMemoryEnvironment.create()

      assert :ok = Task.await(Task.async(fn -> InMemoryEnvironment.destroy(env) end))
      refute Process.alive?(env.ref.agent)
    end

    test "destroy is idempotent when the Agent is already dead" do
      {:ok, env} = InMemoryEnvironment.create()
      :ok = InMemoryEnvironment.destroy(env)
      assert :ok = InMemoryEnvironment.destroy(env)
    end

    test "each env has an isolated file store" do
      {:ok, env1} = InMemoryEnvironment.create()
      {:ok, env2} = InMemoryEnvironment.create()

      :ok = InMemoryEnvironment.write_file(env1, "a.txt", "one")
      :ok = InMemoryEnvironment.write_file(env2, "a.txt", "two")

      assert {:ok, "one"} = InMemoryEnvironment.read_file(env1, "a.txt")
      assert {:ok, "two"} = InMemoryEnvironment.read_file(env2, "a.txt")

      :ok = InMemoryEnvironment.destroy(env1)
      :ok = InMemoryEnvironment.destroy(env2)
    end
  end

  describe "read_file/2 and write_file/3" do
    setup :setup_env

    test "roundtrips relative paths", %{env: env} do
      :ok = InMemoryEnvironment.write_file(env, "lib/foo.ex", "defmodule Foo do\nend")
      assert {:ok, "defmodule Foo do\nend"} = InMemoryEnvironment.read_file(env, "lib/foo.ex")
    end

    test "roundtrips absolute paths rooted at cwd", %{env: env} do
      :ok = InMemoryEnvironment.write_file(env, "/memfs/lib/foo.ex", "hi")
      assert {:ok, "hi"} = InMemoryEnvironment.read_file(env, "lib/foo.ex")
      assert {:ok, "hi"} = InMemoryEnvironment.read_file(env, "/memfs/lib/foo.ex")
    end

    test "overwrites existing content", %{env: env} do
      :ok = InMemoryEnvironment.write_file(env, "a", "v1")
      :ok = InMemoryEnvironment.write_file(env, "a", "v2")
      assert {:ok, "v2"} = InMemoryEnvironment.read_file(env, "a")
    end

    test "read_file returns {:error, :enoent} for missing paths", %{env: env} do
      assert {:error, :enoent} = InMemoryEnvironment.read_file(env, "missing.ex")
    end
  end

  describe "delete_file/2" do
    setup :setup_env

    test "removes a written file", %{env: env} do
      :ok = InMemoryEnvironment.write_file(env, "lib/foo.ex", "x")
      :ok = InMemoryEnvironment.delete_file(env, "lib/foo.ex")

      assert {:error, :enoent} = InMemoryEnvironment.read_file(env, "lib/foo.ex")
    end

    test "is idempotent on missing files", %{env: env} do
      assert :ok = InMemoryEnvironment.delete_file(env, "never_written")
    end
  end

  describe "file_exists?/2" do
    setup :setup_env

    test "false before write, true after, false after delete", %{env: env} do
      refute InMemoryEnvironment.file_exists?(env, "lib/foo.ex")

      :ok = InMemoryEnvironment.write_file(env, "lib/foo.ex", "x")
      assert InMemoryEnvironment.file_exists?(env, "lib/foo.ex")

      :ok = InMemoryEnvironment.delete_file(env, "lib/foo.ex")
      refute InMemoryEnvironment.file_exists?(env, "lib/foo.ex")
    end

    test "returns true for directories that have descendant files", %{env: env} do
      :ok = InMemoryEnvironment.write_file(env, "lib/nested/foo.ex", "x")
      assert InMemoryEnvironment.file_exists?(env, "lib")
      assert InMemoryEnvironment.file_exists?(env, "lib/nested")
    end
  end

  describe "list_directory/2" do
    setup :setup_env

    test "returns immediate children only, deduping subdir names", %{env: env} do
      :ok = InMemoryEnvironment.write_file(env, "a/b.txt", "x")
      :ok = InMemoryEnvironment.write_file(env, "a/c.txt", "x")
      :ok = InMemoryEnvironment.write_file(env, "a/sub/d.txt", "x")
      :ok = InMemoryEnvironment.write_file(env, "a/sub/e.txt", "x")
      :ok = InMemoryEnvironment.write_file(env, "other.txt", "x")

      assert {:ok, children} = InMemoryEnvironment.list_directory(env, "a")
      assert children == ["b.txt", "c.txt", "sub"]
    end

    test "root listing", %{env: env} do
      :ok = InMemoryEnvironment.write_file(env, "a.txt", "x")
      :ok = InMemoryEnvironment.write_file(env, "b/c.txt", "x")

      assert {:ok, children} = InMemoryEnvironment.list_directory(env, "")
      assert children == ["a.txt", "b"]
    end

    test "empty directory returns empty list", %{env: env} do
      assert {:ok, []} = InMemoryEnvironment.list_directory(env, "nope")
    end
  end

  describe "stat/2" do
    setup :setup_env

    test "returns mtime and size for an existing file", %{env: env} do
      :ok = InMemoryEnvironment.write_file(env, "lib/foo.ex", "hello")

      assert {:ok, %{mtime: %DateTime{} = mtime, size: 5}} =
               InMemoryEnvironment.stat(env, "lib/foo.ex")

      now = DateTime.utc_now()
      assert DateTime.diff(now, mtime, :second) in 0..5
    end

    test "returns {:error, :enoent} for missing paths", %{env: env} do
      assert {:error, :enoent} = InMemoryEnvironment.stat(env, "missing.ex")
    end

    test "mtime advances on overwrite", %{env: env} do
      :ok = InMemoryEnvironment.write_file(env, "a", "v1")
      {:ok, %{mtime: t1}} = InMemoryEnvironment.stat(env, "a")

      Process.sleep(2)
      :ok = InMemoryEnvironment.write_file(env, "a", "v2")
      {:ok, %{mtime: t2, size: 2}} = InMemoryEnvironment.stat(env, "a")

      assert DateTime.compare(t2, t1) == :gt
    end
  end

  describe "glob/2" do
    setup :setup_env

    test "matches **/*.ex across nested subdirs", %{env: env} do
      :ok = InMemoryEnvironment.write_file(env, "lib/foo.ex", "x")
      :ok = InMemoryEnvironment.write_file(env, "lib/nested/bar.ex", "x")
      :ok = InMemoryEnvironment.write_file(env, "lib/nested/deeper/baz.ex", "x")
      :ok = InMemoryEnvironment.write_file(env, "README.md", "x")
      :ok = InMemoryEnvironment.write_file(env, "mix.exs", "x")

      assert InMemoryEnvironment.glob(env, "**/*.ex") == [
               "lib/foo.ex",
               "lib/nested/bar.ex",
               "lib/nested/deeper/baz.ex"
             ]
    end

    test "matches * for a single segment only", %{env: env} do
      :ok = InMemoryEnvironment.write_file(env, "lib/foo.ex", "x")
      :ok = InMemoryEnvironment.write_file(env, "lib/nested/bar.ex", "x")

      assert InMemoryEnvironment.glob(env, "lib/*.ex") == ["lib/foo.ex"]
    end

    test "returns [] when nothing matches", %{env: env} do
      :ok = InMemoryEnvironment.write_file(env, "README.md", "x")
      assert InMemoryEnvironment.glob(env, "**/*.ex") == []
    end
  end

  describe "stream_files/3" do
    setup :setup_env

    test "respects roots and emits paths relative to cwd", %{env: env} do
      :ok = InMemoryEnvironment.write_file(env, "lib/foo.ex", "x")
      :ok = InMemoryEnvironment.write_file(env, "lib/nested/bar.ex", "x")
      :ok = InMemoryEnvironment.write_file(env, "test/foo_test.exs", "x")
      :ok = InMemoryEnvironment.write_file(env, "deps/other/mix.exs", "x")
      :ok = InMemoryEnvironment.write_file(env, "CLAUDE.md", "x")

      result =
        env
        |> InMemoryEnvironment.stream_files(["lib", "test"])
        |> Enum.to_list()

      assert result == ["lib/foo.ex", "lib/nested/bar.ex", "test/foo_test.exs"]
    end

    test "emits individual files when root is a file path", %{env: env} do
      :ok = InMemoryEnvironment.write_file(env, "CLAUDE.md", "x")
      :ok = InMemoryEnvironment.write_file(env, "lib/foo.ex", "x")

      result =
        env
        |> InMemoryEnvironment.stream_files(["CLAUDE.md"])
        |> Enum.to_list()

      assert result == ["CLAUDE.md"]
    end

    test "skips roots with no matching files", %{env: env} do
      :ok = InMemoryEnvironment.write_file(env, "lib/foo.ex", "x")

      result =
        env
        |> InMemoryEnvironment.stream_files(["lib", "test", ".code_my_spec"])
        |> Enum.to_list()

      assert result == ["lib/foo.ex"]
    end
  end

  defp setup_env(_ctx) do
    {:ok, env} = InMemoryEnvironment.create()
    on_exit(fn -> InMemoryEnvironment.destroy(env) end)
    {:ok, env: env}
  end
end
