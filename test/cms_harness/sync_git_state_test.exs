defmodule CmsHarness.SyncGitStateTest do
  @moduledoc """
  A dirty `.code_my_spec` submodule must not read as a dirty checkout (c97bb142).

  A QA agent writes into that submodule continuously for the one-to-two hours
  it works — a brief drafted, `prompt.md` regenerated on every task it opens —
  and none of that is code the superproject's own merge would touch. But
  `git status --porcelain --untracked-files=no` reports a submodule with a
  MODIFIED TRACKED file inside it as a dirty path in the superproject too
  (confirmed empirically: a fresh untracked file inside a submodule does not
  trip this, a modification to a file the submodule already tracks does — the
  exact shape "regenerated on every task" is), so `code_on_running_copy`
  refused every promotion for a copy's entire QA session.

  Drives `CmsHarness.Sync.measure_checkout/1` — the real public entry point,
  called on a timer independent of any file scan — against a real git
  checkout with a real submodule, rather than asserting on the private git
  command directly. A fake channel registered the way
  `CmsHarness.AgentsTest` registers one stands in for
  `CmsHarness.Project.ChannelClient`, since `deliver_git_state/2` looks a
  channel up by root and casts to it.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Sync

  setup do
    CmsHarnessTest.Machine.ensure_supervisor()
    :ok
  end

  defp git!(root, args) do
    {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    out
  end

  defp init_repo(root) do
    File.mkdir_p!(root)
    git!(root, ["init", "-q", "-b", "main"])
    git!(root, ["config", "user.email", "spex@example.com"])
    git!(root, ["config", "user.name", "Spex"])
  end

  # A real checkout with a real submodule, one commit into a tracked file the
  # submodule already has — the shape `prompt.md` regenerated on every task
  # takes, not a fresh untracked file (which this bug does not reproduce with
  # at all: confirmed empirically before writing this fixture).
  defp checkout_with_dirty_submodule do
    submodule_root = CodeMySpec.TempFile.dir("sync-git-state-submodule")
    init_repo(submodule_root)
    File.write!(Path.join(submodule_root, "qa_brief.md"), "draft\n")
    git!(submodule_root, ["add", "-A"])
    git!(submodule_root, ["commit", "-q", "-m", "initial brief"])

    checkout_root = CodeMySpec.TempFile.dir("sync-git-state-checkout")
    init_repo(checkout_root)
    File.write!(Path.join(checkout_root, "app.ex"), "defmodule App do\nend\n")
    git!(checkout_root, ["add", "-A"])
    git!(checkout_root, ["commit", "-q", "-m", "initial commit"])

    git!(checkout_root, [
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "add",
      "-q",
      submodule_root,
      ".code_my_spec"
    ])

    git!(checkout_root, ["commit", "-q", "-m", "add submodule"])

    # The QA agent's own act: rewriting a file the submodule already tracks.
    File.write!(Path.join(checkout_root, ".code_my_spec/qa_brief.md"), "in progress\n")

    on_exit(fn ->
      File.rm_rf(submodule_root)
      File.rm_rf(checkout_root)
    end)

    checkout_root
  end

  # A stand-in for `CmsHarness.Project.ChannelClient`, registered where the
  # real one registers. `deliver_git_state/2` looks a channel up by root and
  # casts to it, so anything registered under that key is a channel as far as
  # it knows — same pattern `CmsHarness.AgentsTest`'s `fake_channel/1` uses.
  defp fake_channel(root) do
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)

        receive do
          {:"$gen_cast", {:git_state, state}} -> send(test, {:git_state, state})
        after
          5_000 -> :ok
        end
      end)

    wait_for_registration(root)
    pid
  end

  defp wait_for_registration(root, attempts \\ 100)

  defp wait_for_registration(_root, 0), do: flunk("no channel ever registered")

  defp wait_for_registration(root, attempts) do
    CmsHarness.Registry
    |> Registry.lookup({:channel, root})
    |> registration_result(root, attempts)
  end

  defp registration_result([_], _root, _attempts), do: :ok

  defp registration_result([], root, attempts) do
    Process.sleep(5)
    wait_for_registration(root, attempts - 1)
  end

  test "a submodule with a modified tracked file does not read as a dirty checkout" do
    root = checkout_with_dirty_submodule()
    fake_channel(root)

    Sync.measure_checkout(root)

    assert_receive {:git_state, state}, 5_000

    refute state["dirty"],
           "a QA agent editing a file .code_my_spec already tracks made the whole " <>
             "checkout read as dirty, which is what made code_on_running_copy refuse " <>
             "every promotion for the length of a QA session — the superproject's own " <>
             "merge safety was never affected by a submodule's internal working tree"
  end

  test "a genuinely dirty checkout is still reported dirty" do
    root = checkout_with_dirty_submodule()
    File.write!(Path.join(root, "app.ex"), "defmodule App do\n  def changed, do: true\nend\n")
    fake_channel(root)

    Sync.measure_checkout(root)

    assert_receive {:git_state, state}, 5_000

    assert state["dirty"],
           "ignoring submodule dirt must not also hide a real, uncommitted change " <>
             "to the superproject's own tracked files"
  end
end
