defmodule CodeMySpec.Environments.CliTest do
  use ExUnit.Case
  doctest CodeMySpec.Environments.Cli

  alias CodeMySpec.Environments.Cli
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Environments.MockTmuxAdapter

  setup do
    MockTmuxAdapter.reset!()

    :ok
  end

  describe "create/1" do
    test "creates Environment struct with window name (lazy creation)" do
      session_id = :rand.uniform(10_000)

      assert {:ok, %Environment{} = env} = Cli.create(session_id: session_id)
      assert env.type == :cli
      assert env.ref == "session-#{session_id}"
      assert env.metadata == %{}

      # Window should not be created yet (lazy creation)
      refute MockTmuxAdapter.window_exists?("session-#{session_id}")
    end

    test "includes metadata in Environment struct when provided" do
      session_id = :rand.uniform(10_000)
      metadata = %{foo: "bar", session_id: session_id}

      assert {:ok, %Environment{} = env} = Cli.create(session_id: session_id, metadata: metadata)
      assert env.metadata == metadata
    end

    test "uses random session_id when not provided" do
      assert {:ok, %Environment{} = env} = Cli.create()
      assert env.type == :cli
      assert is_binary(env.ref)
    end
  end

  describe "destroy/1" do
    test "destroys tmux window successfully" do
      {:ok, env} = Cli.create(session_id: :rand.uniform(10_000))

      assert :ok = Cli.destroy(env)
    end

    test "is idempotent (returns :ok even if already destroyed)" do
      {:ok, env} = Cli.create(session_id: :rand.uniform(10_000))

      # Destroy once
      assert :ok = Cli.destroy(env)

      # Destroy again - still succeeds
      assert :ok = Cli.destroy(env)
    end
  end

  describe "read_file/2" do
    test "reads file content from server file system" do
      temp_file = Path.join(System.tmp_dir!(), "test-#{:rand.uniform(10_000)}.txt")
      File.write!(temp_file, "test content")

      {:ok, env} = Cli.create(session_id: :rand.uniform(10_000))

      assert {:ok, "test content"} = Cli.read_file(env, temp_file)

      File.rm!(temp_file)
    end

    test "returns error for non-existent file" do
      {:ok, env} = Cli.create(session_id: :rand.uniform(10_000))

      assert {:error, :enoent} = Cli.read_file(env, "/nonexistent/file.txt")
    end
  end

  describe "list_directory/2" do
    test "lists directory contents from server file system" do
      {:ok, env} = Cli.create(session_id: :rand.uniform(10_000))

      assert {:ok, entries} = Cli.list_directory(env, System.tmp_dir!())
      assert is_list(entries)
    end

    test "returns error for non-existent directory" do
      {:ok, env} = Cli.create(session_id: :rand.uniform(10_000))

      assert {:error, :enoent} = Cli.list_directory(env, "/nonexistent/directory")
    end
  end
end
