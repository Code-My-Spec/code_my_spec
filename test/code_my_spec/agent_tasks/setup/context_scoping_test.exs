defmodule CodeMySpec.AgentTasks.Setup.ContextScopingTest do
  @moduledoc """
  A project's setup answers describe one checkout, not all of them at once.

  `load/1` used to query by project alone and key the result by path with
  `Map.new/2`, which keeps the last of any duplicate — and every checkout
  contributes its own `mix.exs`. Two of this project's working copies are
  *different applications* registered against it (QA fixtures), so `app_name/1`
  answered `qa_sandbox` for `code_my_spec`, and `spex_boundary_ready` sat
  unsatisfiable looking for `qa_sandbox_spex_fixtures.ex` on a project with 1137
  spex already passing. Which row won came down to row order, so it could change
  on any sync. Issue `282428a3`.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.Setup.Context
  alias CodeMySpec.Files
  alias CodeMySpec.WorkingCopies

  # Written through the scope of the copy it belongs to, which is how it happens
  # for real: `upsert_file_metadata/2` takes the working copy from the caller's
  # scope, so a row for another checkout is a row somebody else's harness wrote.
  defp mix_exs_for(scope, working_copy_id, app) do
    Files.upsert_file_metadata(%{scope | active_working_copy_id: working_copy_id}, %{
      path: "mix.exs",
      role: :mix_exs,
      mtime: DateTime.utc_now(),
      size: 1,
      fingerprint: "mix-#{app}",
      validation_errors: %{"data" => %{"app_name" => app}}
    })

    :ok
  end

  test "the app name comes from this checkout's mix.exs, not another's" do
    scope = full_scope_fixture()
    {:ok, device} = CodeMySpec.Devices.announce(scope, nil, %{hostname: "box", kind: :local})

    {:ok, other} =
      WorkingCopies.issue(scope, nil, label: "a QA fixture checkout", device: device)

    # The caller's own checkout says what the app is.
    mix_exs_for(scope, scope.active_working_copy_id, "code_my_spec")
    # A foreign application registered as a copy of this project says otherwise.
    mix_exs_for(scope, other.id, "qa_sandbox")

    assert scope |> Context.load() |> Context.app_name() == "code_my_spec", """
    The app name came from a checkout the caller is not in. Every consumer of
    this is a setup checker asking whether *this* checkout is configured, and a
    wrong answer here made a satisfied requirement unsatisfiable.
    """
  end

  test "a file present only in another checkout is not reported as present here" do
    scope = full_scope_fixture()
    {:ok, device} = CodeMySpec.Devices.announce(scope, nil, %{hostname: "box", kind: :local})
    {:ok, other} = WorkingCopies.issue(scope, nil, label: "another checkout", device: device)

    Files.upsert_file_metadata(%{scope | active_working_copy_id: other.id}, %{
      path: "test/support/fixtures/somewhere_else_spex_fixtures.ex",
      role: :test_support,
      mtime: DateTime.utc_now(),
      size: 1,
      fingerprint: "elsewhere"
    })

    ctx = Context.load(scope)

    refute Context.file(ctx, "test/support/fixtures/somewhere_else_spex_fixtures.ex"), """
    A file that exists only in a different checkout was reported as present in
    this one. `Files.list_files/1` scopes for exactly this reason: one present
    in one checkout and absent in another reads as present.
    """
  end

  test "a scope with no checkout still answers, rather than reporting nothing set up" do
    scope = full_scope_fixture()
    mix_exs_for(scope, scope.active_working_copy_id, "code_my_spec")

    sessionless = %{scope | active_working_copy_id: nil}

    assert sessionless |> Context.load() |> Context.app_name() == "code_my_spec", """
    A scope with no working copy — a mix task, the web UI — got a narrowed
    query and would report every setup step as missing. "I cannot tell" and
    "it is not there" are different answers.
    """
  end
end
