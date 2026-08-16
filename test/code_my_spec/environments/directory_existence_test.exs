defmodule CodeMySpec.Environments.DirectoryExistenceTest do
  @moduledoc """
  What every backend must answer about a directory.

  `Knowledge.resolve_root/2` asked `file_exists?` whether `.code_my_spec/knowledge`
  was there. Four implementations answer `true` for a directory — `File.exists?`
  in `Local` and `Cli`, `test -e` in `Container`, prefix membership in the
  in-memory backend — and `Harness` answered `false`, because it proxies `stat`
  and `stat` reports `{:error, :not_regular}` for anything that is not a regular
  file.

  So the project knowledge library reported `Directory not found:
  .code_my_spec/knowledge` for a directory present in the working copy, and the
  `WriteBddSpecs` prompt's required reading — the layer it says overrides the
  framework rules — was unreachable from the agent surface. The failure read as
  "this project has no BDD knowledge", so the agent proceeded on the lower-
  precedence layer believing the higher one did not exist.

  It survived because the one backend that got it wrong is the one no test uses:
  every suite runs in memory, where directories work, and production runs over a
  harness, where they did not.

  These pin the contract and the mechanism separately, because the fix depends on
  both: `stat` alone cannot answer existence, and `list_directory` can.

  Not covered here: `Harness` itself. `HarnessTest` deliberately does not mock the
  far side — it applies each op with this same `Environments` API against its own
  disk — so the composition under test there is exactly `Local.stat`, which is
  pinned below.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Support.InMemoryEnvironment
  alias CodeMySpec.TempFile

  setup do
    root = TempFile.dir("directory-existence")
    File.mkdir_p!(Path.join(root, "knowledge/bdd/spex"))
    File.write!(Path.join(root, "knowledge/bdd/spex/surfaces.md"), "# Surfaces\n")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, memory} = InMemoryEnvironment.create(working_dir: "/memfs")
    :ok = Environments.write_file(memory, "knowledge/bdd/spex/surfaces.md", "# Surfaces\n")

    %{local: %Environment{type: :local, cwd: root}, memory: memory}
  end

  describe "the contract Harness broke" do
    test "a directory exists, on disk", %{local: env} do
      assert Environments.file_exists?(env, "knowledge"),
             "a directory is a thing that exists; callers ask this before listing it"
    end

    test "a directory exists, in memory", %{memory: env} do
      assert Environments.file_exists?(env, "knowledge")
    end

    test "an absent path does not, in either", %{local: local, memory: memory} do
      refute Environments.file_exists?(local, "nope")
      refute Environments.file_exists?(memory, "nope")
    end
  end

  # The mechanism, pinned on its own because `Harness.file_exists?` is this
  # composed with a channel hop. `stat` is right to refuse — its callers want a
  # size and an mtime, which a directory has not got — so the bug was asking it
  # a question it does not answer, not its answer.
  describe "why stat cannot stand in for existence" do
    test "stat refuses a directory even though the directory is there", %{local: env} do
      assert {:error, _} = Environments.stat(env, "knowledge")
      assert Environments.file_exists?(env, "knowledge")
    end

    test "stat answers for a regular file", %{local: env} do
      assert {:ok, %{size: size}} = Environments.stat(env, "knowledge/bdd/spex/surfaces.md")
      assert size > 0
    end
  end

  # What `Knowledge` probes with now. It has to distinguish present from absent
  # on its own, or swapping it in would make every directory resolve.
  describe "list_directory as the existence probe" do
    test "lists a directory that is there", %{local: local, memory: memory} do
      assert {:ok, entries} = Environments.list_directory(local, "knowledge/bdd/spex")
      assert "surfaces.md" in entries

      assert {:ok, entries} = Environments.list_directory(memory, "knowledge/bdd/spex")
      assert "surfaces.md" in entries
    end

    test "refuses a directory that is not", %{local: local, memory: memory} do
      assert {:error, _} = Environments.list_directory(local, "knowledge/bdd/nope")
      assert {:error, _} = Environments.list_directory(memory, "knowledge/bdd/nope")
    end
  end
end
