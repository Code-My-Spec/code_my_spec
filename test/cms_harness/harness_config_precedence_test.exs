defmodule CmsHarness.HarnessConfigPrecedenceTest do
  @moduledoc """
  A working copy's identity is what its own `.cms_harness.json` says.

  `CMS_HARNESS_ID` used to be checked before the file, and before this module
  even looked at which root was asking. That is the shape of the outage on
  2026-08-20: a daemon serving three roots answered every one of them with the
  id belonging to whichever session launched it, and on the server one id from
  one OS process reads as a harness reconnecting to its own slot — so each join
  killed the previous. 1078 evictions, one every ~1.4s, every stop hook refused,
  until the daemon was restarted with the variable stripped. Restarting it that
  way stopped the loop dead, which is what confirmed the cause.

  `WorkingCopiesEnvOverrideTest` covers the same defect one layer up, at the
  call site `cc95a187` repointed at `read_file/1`. This covers `read/1` itself,
  which is what `ProjectIdentity.resolve/1` — and therefore every channel join —
  still goes through.

  The variable is not going away: the Claude Code MCP mount interpolates
  environment variables and cannot read a file, and that one consumer is the
  whole reason onboarding writes it. So the fix is precedence, not removal, and
  these assert the precedence.
  """

  # Sync: mutates a node-global OS environment variable.
  use ExUnit.Case, async: false

  alias CmsHarness.HarnessConfig

  setup do
    previous = System.get_env("CMS_HARNESS_ID")
    on_exit(fn -> restore_working_copy_id(previous) end)
    :ok
  end

  defp restore_working_copy_id(nil), do: System.delete_env("CMS_HARNESS_ID")
  defp restore_working_copy_id(value), do: System.put_env("CMS_HARNESS_ID", value)

  defp checkout_with_id(id) do
    root = Path.join(System.tmp_dir!(), "cms_precedence_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, ".cms_harness.json"), Jason.encode!(%{"harness_id" => id}))
    root
  end

  defp bare_checkout do
    root =
      Path.join(System.tmp_dir!(), "cms_precedence_bare_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  test "two checkouts answer with their own ids while the env names a third" do
    a_id = Ecto.UUID.generate()
    b_id = Ecto.UUID.generate()
    a = checkout_with_id(a_id)
    b = checkout_with_id(b_id)

    # The shape a worktree session's own settings.local.json really sets:
    # a valid id, belonging to neither of these.
    System.put_env("CMS_HARNESS_ID", Ecto.UUID.generate())

    assert {:ok, %{working_copy_id: ^a_id}} = HarnessConfig.read(a)

    assert {:ok, %{working_copy_id: ^b_id}} = HarnessConfig.read(b), """
    Two working copies answered with the same id.

    That is the whole outage: the server cannot tell two checkouts apart, one
    OS process holds both channels, and `take_over/3` reads the collision as a
    reconnect and kills the sibling. Forever, about once a second.
    """

    refute HarnessConfig.read(a) == HarnessConfig.read(b)
  end

  test "the env no longer answers a checkout that has no file" do
    # This used to be the case the override existed for: a container handed an
    # id with nowhere to have stored it. It has been deleted rather than
    # re-ordered, because precedence was not enough — the variable belongs to
    # whatever started the daemon, and the daemon serves every checkout on the
    # machine, so one stale value answered for all of them however low its
    # priority.
    #
    # The cost is real and is the point: a sprite must now write a
    # `.cms_harness.json` at provision time rather than being handed an id it
    # never records.
    injected = Ecto.UUID.generate()
    System.put_env("CMS_HARNESS_ID", injected)

    assert :none = HarnessConfig.read(bare_checkout()),
           "a checkout that never wrote down which copy it is took one from the shell"
  end

  test "no file and no env is still :none, not an invented identity" do
    System.delete_env("CMS_HARNESS_ID")

    assert :none = HarnessConfig.read(bare_checkout())
  end

  test "a malformed config errors rather than borrowing the env's id" do
    root = bare_checkout()
    File.write!(Path.join(root, ".cms_harness.json"), "{ not json")
    System.put_env("CMS_HARNESS_ID", Ecto.UUID.generate())

    assert {:error, _} = HarnessConfig.read(root), """
    A checkout whose config is broken took the environment's id instead.

    That is the collapse again, by a narrower route: the id it would borrow
    belongs to a different working copy. Saying so is better — `write/2`
    already refuses to overwrite a malformed config for the same reason.
    """
  end

  test "read_file/1 still ignores the env entirely" do
    id = Ecto.UUID.generate()
    root = checkout_with_id(id)
    System.put_env("CMS_HARNESS_ID", Ecto.UUID.generate())

    assert {:ok, %{working_copy_id: ^id}} = HarnessConfig.read_file(root)
  end
end
