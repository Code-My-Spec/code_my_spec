defmodule CmsHarness.HarnessIdentityTest do
  @moduledoc """
  Which *harness* a working copy is.

  A project id is shared by every checkout of a project; a harness id is not,
  and that is the point — files and problems are statements about a working
  copy. The server issues it and this only keeps it, because every
  client-derived alternative collides on a real case: two containers at
  `/workspace/app`, a generated container hostname, a churning session id.

  The invariant these guard is that an id is never invented and never
  destroyed. Inventing one splits a working copy's rows across two identities;
  destroying one orphans every row already filed under it.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CmsHarness.HarnessIdentity

  setup do
    root = Path.join(System.tmp_dir!(), "cms_harness_id_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "read/1" do
    test "a working copy that has never been issued one says so", %{root: root} do
      assert :none = HarnessIdentity.read(root),
             "not issued yet is ordinary — the first join is what mints it"
    end

    test "an issued id survives a restart", %{root: root} do
      :ok = HarnessIdentity.write(root, "h_abc123")

      assert {:ok, "h_abc123"} = HarnessIdentity.read(root),
             "presenting the same id on reconnect is the whole reason it is written down"
    end

    test "trailing whitespace is not part of the id", %{root: root} do
      File.write!(HarnessIdentity.path(root), "h_abc123\n")

      assert {:ok, "h_abc123"} = HarnessIdentity.read(root)
    end

    test "an empty file is not an identity", %{root: root} do
      File.write!(HarnessIdentity.path(root), "   \n")

      assert :none = HarnessIdentity.read(root),
             "an empty file must not present the empty string as this copy's id"
    end

    test "a file that cannot be read is an error, not 'never issued'", %{root: root} do
      path = HarnessIdentity.path(root)
      File.write!(path, "h_abc123")
      File.chmod!(path, 0o000)
      on_exit(fn -> File.chmod(path, 0o644) end)

      log =
        capture_log(fn ->
          assert {:error, _} = HarnessIdentity.read(root),
                 "reporting this as unissued would ask for a second id and strand " <>
                   "every row filed under the first"
        end)

      assert log =~ "could not be read"
    end
  end

  describe "write/2" do
    test "records the id the server issued", %{root: root} do
      assert :ok = HarnessIdentity.write(root, "h_xyz")
      assert File.read!(HarnessIdentity.path(root)) =~ "h_xyz"
    end

    test "refuses to overwrite an identity it cannot read", %{root: root} do
      path = HarnessIdentity.path(root)
      File.write!(path, "h_original")
      File.chmod!(path, 0o000)
      on_exit(fn -> File.chmod(path, 0o644) end)

      log =
        capture_log(fn ->
          assert {:error, :existing_identity_unreadable} =
                   HarnessIdentity.write(root, "h_replacement")
        end)

      assert log =~ "refusing to overwrite"

      File.chmod!(path, 0o644)

      assert {:ok, "h_original"} = HarnessIdentity.read(root),
             "the only record of the id this copy's rows are filed under has to survive"
    end
  end

  describe "the repo must never carry one" do
    # Criterion 736. A committed id is cloned into every checkout, so a sprite
    # cloning the repo comes up wearing the laptop's identity and both sync into
    # the same rows — the corruption the lease exists to prevent, with no lease
    # left. Deliberately not under `.code_my_spec/`: that is a git submodule, so
    # a file there is untracked here and stageable in the docs repo.
    test "the id file is ignored by this repository" do
      ignored = File.read!(Path.join(File.cwd!(), ".gitignore"))

      assert ignored =~ ".cms_harness_id",
             "if this line goes, an identity can be committed and inherited by every clone"
    end

    test "the id does not live inside the .code_my_spec submodule" do
      refute HarnessIdentity.path("/tmp/wc") =~ ".code_my_spec",
             "a file there is stageable in the docs repo, where a commit would be " <>
               "inherited by everyone who clones it"
    end
  end
end
