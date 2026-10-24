defmodule CodeMySpec.Support.InMemoryExecutionContextTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Support.InMemoryExecutionContext

  describe "create/1 and destroy/1" do
    test "create returns an ExecutionContext with an Agent in ref" do
      {:ok, env} = InMemoryExecutionContext.create()

      assert %ExecutionContext{type: :memory, ref: %{agent: agent}} = env
      assert is_pid(agent)
      assert Process.alive?(agent)

      :ok = InMemoryExecutionContext.destroy(env)
    end

    test "create honors :working_dir" do
      {:ok, env} = InMemoryExecutionContext.create(working_dir: "/tmp/proj")
      assert env.cwd == "/tmp/proj"
      :ok = InMemoryExecutionContext.destroy(env)
    end

    test "destroy stops the Agent" do
      {:ok, env} = InMemoryExecutionContext.create()
      agent = env.ref.agent

      :ok = InMemoryExecutionContext.destroy(env)
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
      {:ok, env} = InMemoryExecutionContext.create()

      results =
        1..20
        |> Task.async_stream(fn _ -> InMemoryExecutionContext.destroy(env) end,
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
      {:ok, env} = InMemoryExecutionContext.create()

      assert :ok = Task.await(Task.async(fn -> InMemoryExecutionContext.destroy(env) end))
      refute Process.alive?(env.ref.agent)
    end

    test "destroy is idempotent when the Agent is already dead" do
      {:ok, env} = InMemoryExecutionContext.create()
      :ok = InMemoryExecutionContext.destroy(env)
      assert :ok = InMemoryExecutionContext.destroy(env)
    end

    test "each env has an isolated file store" do
      {:ok, env1} = InMemoryExecutionContext.create()
      {:ok, env2} = InMemoryExecutionContext.create()

      :ok = InMemoryExecutionContext.write_file(env1, "a.txt", "one")
      :ok = InMemoryExecutionContext.write_file(env2, "a.txt", "two")

      assert {:ok, "one"} = InMemoryExecutionContext.read_file(env1, "a.txt")
      assert {:ok, "two"} = InMemoryExecutionContext.read_file(env2, "a.txt")

      :ok = InMemoryExecutionContext.destroy(env1)
      :ok = InMemoryExecutionContext.destroy(env2)
    end
  end

  describe "read_file/2 and write_file/3" do
    setup :setup_env

    test "roundtrips relative paths", %{env: env} do
      :ok = InMemoryExecutionContext.write_file(env, "lib/foo.ex", "defmodule Foo do\nend")

      assert {:ok, "defmodule Foo do\nend"} =
               InMemoryExecutionContext.read_file(env, "lib/foo.ex")
    end

    test "roundtrips absolute paths rooted at cwd", %{env: env} do
      :ok = InMemoryExecutionContext.write_file(env, "/memfs/lib/foo.ex", "hi")
      assert {:ok, "hi"} = InMemoryExecutionContext.read_file(env, "lib/foo.ex")
      assert {:ok, "hi"} = InMemoryExecutionContext.read_file(env, "/memfs/lib/foo.ex")
    end

    test "overwrites existing content", %{env: env} do
      :ok = InMemoryExecutionContext.write_file(env, "a", "v1")
      :ok = InMemoryExecutionContext.write_file(env, "a", "v2")
      assert {:ok, "v2"} = InMemoryExecutionContext.read_file(env, "a")
    end

    test "read_file returns {:error, :enoent} for missing paths", %{env: env} do
      assert {:error, :enoent} = InMemoryExecutionContext.read_file(env, "missing.ex")
    end
  end

  describe "delete_file/2" do
    setup :setup_env

    test "removes a written file", %{env: env} do
      :ok = InMemoryExecutionContext.write_file(env, "lib/foo.ex", "x")
      :ok = InMemoryExecutionContext.delete_file(env, "lib/foo.ex")

      assert {:error, :enoent} = InMemoryExecutionContext.read_file(env, "lib/foo.ex")
    end

    test "is idempotent on missing files", %{env: env} do
      assert :ok = InMemoryExecutionContext.delete_file(env, "never_written")
    end
  end

  describe "file_exists?/2" do
    setup :setup_env

    test "false before write, true after, false after delete", %{env: env} do
      refute InMemoryExecutionContext.file_exists?(env, "lib/foo.ex")

      :ok = InMemoryExecutionContext.write_file(env, "lib/foo.ex", "x")
      assert InMemoryExecutionContext.file_exists?(env, "lib/foo.ex")

      :ok = InMemoryExecutionContext.delete_file(env, "lib/foo.ex")
      refute InMemoryExecutionContext.file_exists?(env, "lib/foo.ex")
    end

    test "returns true for directories that have descendant files", %{env: env} do
      :ok = InMemoryExecutionContext.write_file(env, "lib/nested/foo.ex", "x")
      assert InMemoryExecutionContext.file_exists?(env, "lib")
      assert InMemoryExecutionContext.file_exists?(env, "lib/nested")
    end
  end

  describe "list_directory/2" do
    setup :setup_env

    test "returns immediate children only, deduping subdir names", %{env: env} do
      :ok = InMemoryExecutionContext.write_file(env, "a/b.txt", "x")
      :ok = InMemoryExecutionContext.write_file(env, "a/c.txt", "x")
      :ok = InMemoryExecutionContext.write_file(env, "a/sub/d.txt", "x")
      :ok = InMemoryExecutionContext.write_file(env, "a/sub/e.txt", "x")
      :ok = InMemoryExecutionContext.write_file(env, "other.txt", "x")

      assert {:ok, children} = InMemoryExecutionContext.list_directory(env, "a")
      assert children == ["b.txt", "c.txt", "sub"]
    end

    test "root listing", %{env: env} do
      :ok = InMemoryExecutionContext.write_file(env, "a.txt", "x")
      :ok = InMemoryExecutionContext.write_file(env, "b/c.txt", "x")

      assert {:ok, children} = InMemoryExecutionContext.list_directory(env, "")
      assert children == ["a.txt", "b"]
    end

    # Named "empty directory" but asking about one that does not exist, and it
    # asserted `{:ok, []}` — which is what `File.ls` answers for a directory
    # that is there and empty, not for one that is absent. That gap was load
    # bearing: callers branch on the tuple, so `match?({:ok, _}, ...)` made
    # every path a directory.
    #
    # A map keyed by file path cannot distinguish an empty directory from an
    # absent one, and absent is the answer worth being right about: the
    # analyzers this stands in for ask whether anything is there.
    test "a directory with nothing under it does not exist", %{env: env} do
      assert {:error, :enoent} = InMemoryExecutionContext.list_directory(env, "nope")
    end
  end

  describe "stat/2" do
    setup :setup_env

    test "returns mtime and size for an existing file", %{env: env} do
      :ok = InMemoryExecutionContext.write_file(env, "lib/foo.ex", "hello")

      assert {:ok, %{mtime: %DateTime{} = mtime, size: 5}} =
               InMemoryExecutionContext.stat(env, "lib/foo.ex")

      now = DateTime.utc_now()
      assert DateTime.diff(now, mtime, :second) in 0..5
    end

    test "returns {:error, :enoent} for missing paths", %{env: env} do
      assert {:error, :enoent} = InMemoryExecutionContext.stat(env, "missing.ex")
    end

    test "mtime advances on overwrite", %{env: env} do
      :ok = InMemoryExecutionContext.write_file(env, "a", "v1")
      {:ok, %{mtime: t1}} = InMemoryExecutionContext.stat(env, "a")

      Process.sleep(2)
      :ok = InMemoryExecutionContext.write_file(env, "a", "v2")
      {:ok, %{mtime: t2, size: 2}} = InMemoryExecutionContext.stat(env, "a")

      assert DateTime.compare(t2, t1) == :gt
    end
  end

  describe "glob/2" do
    setup :setup_env

    test "matches **/*.ex across nested subdirs", %{env: env} do
      :ok = InMemoryExecutionContext.write_file(env, "lib/foo.ex", "x")
      :ok = InMemoryExecutionContext.write_file(env, "lib/nested/bar.ex", "x")
      :ok = InMemoryExecutionContext.write_file(env, "lib/nested/deeper/baz.ex", "x")
      :ok = InMemoryExecutionContext.write_file(env, "README.md", "x")
      :ok = InMemoryExecutionContext.write_file(env, "mix.exs", "x")

      assert InMemoryExecutionContext.glob(env, "**/*.ex") == [
               "lib/foo.ex",
               "lib/nested/bar.ex",
               "lib/nested/deeper/baz.ex"
             ]
    end

    test "matches * for a single segment only", %{env: env} do
      :ok = InMemoryExecutionContext.write_file(env, "lib/foo.ex", "x")
      :ok = InMemoryExecutionContext.write_file(env, "lib/nested/bar.ex", "x")

      assert InMemoryExecutionContext.glob(env, "lib/*.ex") == ["lib/foo.ex"]
    end

    test "returns [] when nothing matches", %{env: env} do
      :ok = InMemoryExecutionContext.write_file(env, "README.md", "x")
      assert InMemoryExecutionContext.glob(env, "**/*.ex") == []
    end
  end

  describe "stream_files/3" do
    setup :setup_env

    test "respects roots and emits paths relative to cwd", %{env: env} do
      :ok = InMemoryExecutionContext.write_file(env, "lib/foo.ex", "x")
      :ok = InMemoryExecutionContext.write_file(env, "lib/nested/bar.ex", "x")
      :ok = InMemoryExecutionContext.write_file(env, "test/foo_test.exs", "x")
      :ok = InMemoryExecutionContext.write_file(env, "deps/other/mix.exs", "x")
      :ok = InMemoryExecutionContext.write_file(env, "CLAUDE.md", "x")

      result =
        env
        |> InMemoryExecutionContext.stream_files(["lib", "test"])
        |> Enum.to_list()

      assert result == ["lib/foo.ex", "lib/nested/bar.ex", "test/foo_test.exs"]
    end

    test "emits individual files when root is a file path", %{env: env} do
      :ok = InMemoryExecutionContext.write_file(env, "CLAUDE.md", "x")
      :ok = InMemoryExecutionContext.write_file(env, "lib/foo.ex", "x")

      result =
        env
        |> InMemoryExecutionContext.stream_files(["CLAUDE.md"])
        |> Enum.to_list()

      assert result == ["CLAUDE.md"]
    end

    test "skips roots with no matching files", %{env: env} do
      :ok = InMemoryExecutionContext.write_file(env, "lib/foo.ex", "x")

      result =
        env
        |> InMemoryExecutionContext.stream_files(["lib", "test", ".code_my_spec"])
        |> Enum.to_list()

      assert result == ["lib/foo.ex"]
    end
  end

  defp setup_env(_ctx) do
    {:ok, env} = InMemoryExecutionContext.create()
    on_exit(fn -> InMemoryExecutionContext.destroy(env) end)
    {:ok, env: env}
  end
end
