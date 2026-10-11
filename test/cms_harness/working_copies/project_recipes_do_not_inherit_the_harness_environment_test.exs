defmodule CmsHarness.WorkingCopies.ProjectRecipesDoNotInheritTheHarnessEnvironmentTest do
  use ExUnit.Case, async: false

  alias CmsHarness.WorkingCopies.Create

  @moduletag :tmp_dir

  setup do
    previous = System.get_env("MIX_ENV")
    previous_probe = System.get_env("CMS_RECIPE_TEST_PROBE")
    System.put_env("MIX_ENV", "harness")
    System.put_env("CMS_RECIPE_TEST_PROBE", "the-daemon")

    on_exit(fn ->
      restore_env("CMS_RECIPE_TEST_PROBE", previous_probe)
      restore_env("MIX_ENV", previous)
    end)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  test "worktree initialization does not inherit the daemon's environment", %{tmp_dir: root} do
    File.write!(Path.join(root, "justfile"), """
    init-worktree name target:
        #!/usr/bin/env bash
        printf 'mix=%s cms=%s' "${MIX_ENV-unset}" "${CMS_RECIPE_TEST_PROBE-unset}"
        exit 23
    """)

    # Stop after observing the real recipe, before onboarding a checkout.
    assert {:error, {:worktree_failed, 23, output}} =
             Create.run(root, %{"label" => "gate", "root" => Path.join(root, "copy")})

    assert output =~ "mix=unset cms=unset"
    assert System.get_env("MIX_ENV") == "harness"
  end

  test "gate setup starts without the daemon's environment", %{tmp_dir: root} do
    File.write!(Path.join(root, ".cms_harness_preparing"), "preparing\n")

    File.write!(Path.join(root, "justfile"), """
    gate-setup:
        #!/usr/bin/env bash
        set -eu
        test "${MIX_ENV-unset}" = unset
        test "${CMS_RECIPE_TEST_PROBE-unset}" = unset
        printf ready > checked
    """)

    assert :ok = Create.prepare(root)
    assert File.read!(Path.join(root, "checked")) == "ready"
    refute Create.preparing?(root)
  end

  test "a project can explicitly choose its recipe's Mix environment", %{tmp_dir: root} do
    File.write!(Path.join(root, "justfile"), """
    gate-setup:
        #!/usr/bin/env bash
        export MIX_ENV=test
        printf '%s' "$MIX_ENV" > chosen-environment
    """)

    assert :ok = Create.prepare(root)
    assert File.read!(Path.join(root, "chosen-environment")) == "test"
  end
end
