defmodule CmsHarness.ProjectIdentityTest do
  @moduledoc """
  Which project a directory is — answered here, on the machine that has the
  directory, because a server with no disk cannot look a path up.

  The order is the working copy's own `config.yml`, then `CMS_PROJECT_ID`, then
  refuse. There is deliberately no fourth step: guessing means syncing one
  checkout's files over another project's rows.

  It used to be the other way round, and one of these tests said so — "the
  environment wins, which is what a sprite relies on". That is true of a sprite
  and wrong of everything else, because `resolve/1` is called once per working
  copy while the variable belongs to whatever started the daemon. See the
  replacement below.
  """

  # Sync: this mutates OS environment variables, which belong to the BEAM node
  # rather than to a test process. Saving and restoring them is careful and
  # still leaves a window every concurrent test can see.

  use ExUnit.Case, async: false

  import CmsHarnessTest.Projects

  alias CmsHarness.ProjectIdentity

  setup do
    previous = System.get_env("CMS_PROJECT_ID")
    System.delete_env("CMS_PROJECT_ID")

    on_exit(fn -> restore("CMS_PROJECT_ID", previous) end)

    :ok
  end

  # Two clauses rather than an `if`. Restoring to "it was not set" is a distinct
  # case, not the negative of one, and the project's credo rule bans imperative
  # branching anywhere in a test file — helpers included, which is why this is
  # matched rather than `case`d.
  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)

  test "reads the id out of the project's config" do
    project = project_dir(project_id: 712)

    assert {:ok, %{id: "712"}} = ProjectIdentity.resolve(project.root)
  end

  describe "server_url/1" do
    # The tier that answers before a copy exists. `--server-url` and the copy's
    # own `.cms_harness.json` both come after this in `cms.harness.onboard`, and
    # neither can help the *first* onboard of a checkout somebody else's build is
    # pointed at — the file is not written yet and nobody typed anything. A
    # committed key every clone inherits is the only thing that can (a6d07cf3).
    test "a project names the server its ids are minted against" do
      project = project_dir(project_id: 712)

      File.write!(
        Path.join(project.root, ".code_my_spec/config.yml"),
        """
        project_id: 712
        server_url: "https://project.example"
        description: "a hand-written block
        that spans several lines and must not be re-serialised"
        """
      )

      assert ProjectIdentity.server_url(project.root) == "https://project.example",
             "a checkout that says which CodeMySpec it belongs to was ignored, so " <>
               "its id gets minted against whichever build ran the command"
    end

    # `nil` rather than a guess, because the tier below it — the build's own
    # default — is the right answer for every project that has never set this,
    # which is all of them today.
    test "a project that names none says so" do
      project = project_dir(project_id: 712)

      assert ProjectIdentity.server_url(project.root) == nil
    end

    test "a directory with no config at all says so" do
      assert ProjectIdentity.server_url("/nonexistent/checkout") == nil
    end
  end

  # The inverted version of the test that used to live here. It asserted that
  # an exported id wins over a checkout's own config, which is the shape that
  # let one harness attribute every copy it serves to whichever project the
  # launching session happened to export. Story 1000's criterion 737 states the
  # rule the other way — "an agent learns which project it serves from its
  # identity, not from its environment" — and names this exact scenario, but it
  # drives the hook endpoint, where the project comes from the harness record,
  # so it never saw this path.
  #
  # Measured 2026-08-20 before the fix: a scratch copy whose config named
  # `11111111-…` minted a harness against `708492f9-…`, the id exported in the
  # session that ran the command, with nothing in the output naming the swap.
  test "a checkout's own config wins over an id exported in the shell" do
    project = project_dir(project_id: 712)
    System.put_env("CMS_PROJECT_ID", "999")

    assert {:ok, %{id: "712"}} = ProjectIdentity.resolve(project.root),
           "an exported CMS_PROJECT_ID redirected a working copy that says which " <>
             "project it is. A developer with two projects in two terminals has " <>
             "that variable set, and this decides whose rows a checkout's files " <>
             "are written to."
  end

  # The half the old test was right about, kept — this is the sprite: one VM,
  # one project, no config file of its own to read.
  test "a copy that names no project falls through to the environment" do
    System.put_env("CMS_PROJECT_ID", "999")

    assert {:ok, %{id: "999"}} = ProjectIdentity.resolve(anonymous_dir())
  end

  # The same source answers both questions. A copy whose project came from its
  # own config takes its harness id from its own file; only the sprite — which
  # had no config to read — falls through to the environment for either.
  #
  # Without this, a never-onboarded directory presents the launching session's
  # harness id on join. `Analysis.take_over/3` refuses that now (same id,
  # different root) so it announces itself instead of evicting the rightful
  # holder — but carrying a borrowed id and being refused is a worse answer than
  # carrying none and being issued one.
  test "a copy with a config and no harness file has no harness id, whatever the shell exports" do
    project = project_dir(project_id: 712)
    previous = System.get_env("CMS_HARNESS_ID")
    System.put_env("CMS_HARNESS_ID", "borrowed-from-another-checkout")

    on_exit(fn -> restore("CMS_HARNESS_ID", previous) end)

    File.rm(Path.join(project.root, ".cms_harness.json"))

    assert {:ok, %{working_copy_id: nil}} = ProjectIdentity.resolve(project.root)
  end

  # A copy that resolved its project through the environment is not
  # necessarily a fresh sprite — it might be a real, already-onboarded working
  # copy that simply never got a `.code_my_spec/config.yml` of its own (an
  # external project onboarded onto a harness for testing, say). Its
  # `.cms_harness.json` is still the right answer and has to win over whatever
  # id the launching session happened to export.
  #
  # Measured 2026-08-20 on exactly this shape: a real working copy, onboarded,
  # with its own correct `.cms_harness.json`, no `config.yml` — every join
  # presented the daemon's own exported CMS_HARNESS_ID instead, because that
  # was checked before the file naming its real one.
  test "a copy with no config but a real harness file uses the file, not the shell" do
    project = project_dir(project_id: nil)
    System.put_env("CMS_PROJECT_ID", "999")

    previous = System.get_env("CMS_HARNESS_ID")
    System.put_env("CMS_HARNESS_ID", "borrowed-from-another-checkout")
    on_exit(fn -> restore("CMS_HARNESS_ID", previous) end)

    assert {:ok, %{working_copy_id: working_copy_id}} = ProjectIdentity.resolve(project.root)
    assert working_copy_id == project.working_copy_id
    refute working_copy_id == "borrowed-from-another-checkout"
  end

  # The same rule for `project_id`, which is the half that decides which
  # project's rows a checkout's files are written to.
  #
  # `.cms_harness.json` carries both ids and only `working_copy_id` was read here, so
  # an onboarded copy with no `config.yml` fell past its own answer to the
  # variable. Measured 2026-08-21 from harness.log, one daemon serving three
  # roots:
  #
  #     serving project 708492f9-… at …/broken_oaths
  #     serving project 708492f9-… at …/code_my_spec
  #     serving project 708492f9-… at …/code_my_spec/.claude/worktrees/…
  #
  # `broken_oaths` is a different repository. Its `.cms_harness.json` said
  # `49760b8b-…`; the daemon carried `CMS_PROJECT_ID=708492f9-…` from the
  # session that started it. So its files reconciled into CodeMySpec's project
  # and its spex answered CodeMySpec's spex requests, leaving 96 warnings that
  # read `could not read spec file .code_my_spec/spec/broken_oaths/…
  # (:enoent)` — a row written from one checkout, looked for in another.
  test "a copy with no config but a harness file naming a project uses that project" do
    project = project_dir()
    File.rm!(Path.join(project.root, ".code_my_spec/config.yml"))
    System.put_env("CMS_PROJECT_ID", "999")

    assert {:ok, %{id: id}} = ProjectIdentity.resolve(project.root)

    assert id == project.id
    refute id == "999"
  end

  # And it takes its harness id from that same file, for the reason the
  # `config.yml` case does: one file names this working copy, and an identity
  # assembled from two sources is two things that can disagree.
  test "and its harness id comes from the same file" do
    project = project_dir()
    File.rm!(Path.join(project.root, ".code_my_spec/config.yml"))

    previous = System.get_env("CMS_HARNESS_ID")
    System.put_env("CMS_HARNESS_ID", "borrowed-from-another-checkout")
    on_exit(fn -> restore("CMS_HARNESS_ID", previous) end)

    assert {:ok, %{working_copy_id: working_copy_id}} = ProjectIdentity.resolve(project.root)
    assert working_copy_id == project.working_copy_id
  end

  # Not refused, said. A daemon that would not start over a variable it
  # inherited is much harder to diagnose from the inside than one that starts
  # and names which of the two it took — and the line has to name the file, or
  # the reader cannot tell which of the copy's two identity files answered.
  #
  # Said by `log_env_disagreement/1` rather than by `resolve/1`, and the split
  # is the point. `resolve/1` runs once per working copy *per resolution* —
  # every hook, every operation — so a permanent disagreement said itself
  # forever: 787 identical warnings in two hours on one machine. It is now
  # emitted from `Projects.ensure_started/1`'s serving branch, which is reached
  # once per root per daemon, the rate this fact actually changes at.
  test "a harness file disagreeing with the shell is logged, naming the file" do
    project = project_dir()
    File.rm!(Path.join(project.root, ".code_my_spec/config.yml"))
    System.put_env("CMS_PROJECT_ID", "999")

    {:ok, resolved} = ProjectIdentity.resolve(project.root)

    log = ExUnit.CaptureLog.capture_log(fn -> ProjectIdentity.log_env_disagreement(resolved) end)

    assert log =~ ".cms_harness.json"
    assert log =~ "999"
  end

  # The half that keeps the fix honest: resolving is silent, so the number of
  # these lines tracks working copies rather than hook traffic.
  test "resolving does not log the disagreement on every call" do
    project = project_dir()
    File.rm!(Path.join(project.root, ".code_my_spec/config.yml"))
    System.put_env("CMS_PROJECT_ID", "999")

    log = ExUnit.CaptureLog.capture_log(fn -> ProjectIdentity.resolve(project.root) end)

    refute log =~ "CMS_PROJECT_ID says"
  end

  test "and there is nothing to say when the two agree" do
    project = project_dir(project_id: 712)
    System.put_env("CMS_PROJECT_ID", "712")

    {:ok, resolved} = ProjectIdentity.resolve(project.root)

    log = ExUnit.CaptureLog.capture_log(fn -> ProjectIdentity.log_env_disagreement(resolved) end)

    refute log =~ "CMS_PROJECT_ID says"
  end

  # A copy that names no working copy of its own does not borrow one.
  #
  # `CMS_HARNESS_ID` used to answer here, which is what the sprite relied on:
  # no config, no harness file, one VM, identity injected by whatever started
  # it. That fallback is gone. The variable belongs to the launching process and
  # the daemon serves every checkout on the machine, so one stale value answered
  # for all of them — a worktree's requirement rows were written against the main
  # checkout and read back as somebody else's verdict (`5b538c8b`).
  #
  # The project still resolves, because `CMS_PROJECT_ID` is a separate fallback
  # and was not part of that failure. What a copy no longer gets is an identity
  # it never wrote down.
  #
  # CONSEQUENCE, deliberately asserted rather than discovered: a sprite must now
  # write a `.cms_harness.json` at provision time. Until it does, it resolves a
  # project and no working copy.
  test "a copy with neither config nor harness file gets no working copy" do
    System.put_env("CMS_PROJECT_ID", "999")

    previous = System.get_env("CMS_HARNESS_ID")
    System.put_env("CMS_HARNESS_ID", "sprite-issued-id")
    on_exit(fn -> restore("CMS_HARNESS_ID", previous) end)

    assert {:ok, %{id: "999", working_copy_id: nil}} =
             ProjectIdentity.resolve(anonymous_dir())
  end

  test "a directory that cannot say which project it is gets an error, not a guess" do
    assert {:error, :no_project_id} = ProjectIdentity.resolve(anonymous_dir())
  end

  test "a config with no project_id is refused rather than half-resolved" do
    project = project_dir(project_id: nil)
    write(project.root, ".code_my_spec/config.yml", "account_id: 1\n")

    assert {:error, :no_project_id} = ProjectIdentity.resolve(project.root)
  end

  test "a config that is not YAML says so, distinctly from having no id" do
    project = project_dir(project_id: nil)
    write(project.root, ".code_my_spec/config.yml", "project_id: [unclosed\n")

    assert {:error, {:invalid_config, _}} = ProjectIdentity.resolve(project.root)
  end

  test "the root is absolute, so two spellings of one checkout are one project" do
    project = project_dir(project_id: 712)
    {:ok, %{root: root}} = ProjectIdentity.resolve(project.root <> "/./")

    assert root == Path.expand(project.root)
  end

  # `project_id: 712` in YAML is an integer; the channel topic is a string. If
  # the two spellings reached the topic the harness would join two different
  # channels for one project.
  test "an integer id becomes the string the topic needs" do
    project = project_dir(project_id: nil)
    write(project.root, ".code_my_spec/config.yml", "project_id: 712\n")

    assert {:ok, %{id: "712"}} = ProjectIdentity.resolve(project.root)
  end
end
