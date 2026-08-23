defmodule CmsHarness.HarnessConfigTest do
  @moduledoc """
  A working copy says which harness it is, in one file.

  There used to be two writers: `HarnessIdentity` wrote an id-only
  `.cms_working_copy_id` when the server issued one, and this wrote
  `.cms_harness.json` at onboarding. A copy that went through both carried two
  files naming two harnesses — devops-qa held `5d5c599b` in one and `8a663385`
  in the other — with nothing on disk saying which counted. Reading preferred
  the JSON, so behaviour was never ambiguous, but the first person to look
  concluded they disagreed.

  One file now, no fallback, one writer.
  """
  # Sync: sets OS environment variables. `HarnessConfig.read/1` checks the
  # environment before the file, so one exported value makes every working copy
  # in the suite resolve to the same harness.
  use ExUnit.Case, async: false

  alias CmsHarness.HarnessConfig

  @id "8a663385-d043-4538-bcb3-4b4a31a8c207"
  @other "5d5c599b-4be7-4e41-8c94-3ab878cab753"

  setup do
    {:ok, root} = Briefly.create(directory: true)
    prior = System.get_env("CMS_HARNESS_ID")
    System.delete_env("CMS_HARNESS_ID")

    on_exit(fn -> restore(prior) end)

    %{root: root}
  end

  # Both directions. Restoring only when there *was* a prior value leaves the
  # override set for every test that follows, and `read/1` checks the
  # environment before the file — so every working copy in the suite resolves to
  # this id. That is what broke four identity tests that pass alone.
  #
  # Two clauses rather than a `case`, matching `CmsHarnessConnCase.restore/1`,
  # which has handled the same hazard correctly since it was written.
  defp restore(nil), do: System.delete_env("CMS_HARNESS_ID")
  defp restore(value), do: System.put_env("CMS_HARNESS_ID", value)

  describe "read/1" do
    test "returns what was written, root included", %{root: root} do
      :ok = HarnessConfig.write(root, %{working_copy_id: @id, project_id: "p1", root: root})

      assert {:ok, %{working_copy_id: @id, project_id: "p1", root: written}} =
               HarnessConfig.read(root)

      assert Path.expand(written) == Path.expand(root)
    end

    test "no file is not an error", %{root: root} do
      assert :none = HarnessConfig.read(root)
    end

    # The legacy id-only file is gone, not fallen back to. A copy still holding
    # one has no identity as far as this is concerned, which is the point: two
    # files is the state being removed.
    test "a legacy .cms_working_copy_id is not read", %{root: root} do
      File.write!(Path.join(root, ".cms_harness_id"), @other <> "\n")

      assert :none = HarnessConfig.read(root),
             "falling back is what let two files coexist"
    end

    test "a malformed config is an error, not an absence", %{root: root} do
      File.write!(HarnessConfig.path(root), "not json")

      assert {:error, :malformed} = HarnessConfig.read(root),
             "absence means 'ask for one'; malformed means 'a human should look'"
    end
  end

  describe "CMS_HARNESS_ID" do
    # Was "overrides the file", and asserted the opposite of this.
    #
    # The override was written for one shape — a container handed an id, with no
    # file to have stored it in — and it was implemented as "env wins", which is
    # a different and much larger claim. Onboarding writes the variable into
    # every checkout's `settings.local.json` (the MCP mount interpolates env and
    # cannot read a file), `just refresh-harness` is designed to be launched
    # from any session, and the daemon inherits it. Serving N roots, it then
    # answered every one of them with the launching session's id.
    #
    # On the server that is one id from one OS process, which `take_over/3`
    # reads as a harness reconnecting to its own slot — so each join killed the
    # previous. 1078 evictions, about one every 1.4s, every stop hook refused.
    # Restarting the daemon with the variable stripped stopped it dead, which is
    # how the cause was confirmed.
    #
    # The override survives for the case it was written for: no file. See
    # `HarnessConfigPrecedenceTest` for the full precedence.
    test "does not override a file that names an id", %{root: root} do
      :ok = HarnessConfig.write(root, %{working_copy_id: @id, project_id: "p1", root: root})
      System.put_env("CMS_HARNESS_ID", @other)

      assert {:ok, %{working_copy_id: @id}} = HarnessConfig.read(root),
             "the file is the one that knows which working copy it is sitting in"
    end

    test "answers a working copy that has no file — the case it exists for", %{root: root} do
      System.put_env("CMS_HARNESS_ID", @other)

      assert {:ok, %{working_copy_id: @other}} = HarnessConfig.read(root)
    end

    test "reading it does not write it — an override that outlived itself would be worse",
         %{root: root} do
      System.put_env("CMS_HARNESS_ID", @other)

      assert {:ok, %{working_copy_id: @other}} = HarnessConfig.read(root)

      refute File.exists?(HarnessConfig.path(root)),
             "a one-off override persisted to disk survives the run that set it"
    end
  end

  describe "write/2" do
    # Carried over from HarnessIdentity: a config that exists but cannot be read
    # reads as "not issued", so a mint can arrive for a copy that already has
    # one. Writing it would destroy the only record of the id its rows are filed
    # under.
    test "refuses to overwrite a config it cannot read", %{root: root} do
      File.write!(HarnessConfig.path(root), "not json")

      assert {:error, :existing_identity_unreadable} =
               HarnessConfig.write(root, %{working_copy_id: @id, project_id: "p1", root: root})

      assert File.read!(HarnessConfig.path(root)) == "not json"
    end

    test "overwrites a readable config", %{root: root} do
      :ok = HarnessConfig.write(root, %{working_copy_id: @other, project_id: "p1", root: root})
      :ok = HarnessConfig.write(root, %{working_copy_id: @id, project_id: "p1", root: root})

      assert {:ok, %{working_copy_id: @id}} = HarnessConfig.read(root)
    end
  end
end
