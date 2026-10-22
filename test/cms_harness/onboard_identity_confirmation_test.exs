defmodule CmsHarness.OnboardIdentityConfirmationTest do
  @moduledoc """
  45cb6b07: `Staffing.offboard/2` deletes the server's working-copy row but
  never touches the checkout's own files, so a recorded `working_copy_id`
  used to be trusted on faith forever -- a checkout re-onboarded after an
  explicit offboard stayed invisible to the server with nothing anywhere
  saying so. `Onboard.handle_confirmation/5` is the decision `identity/3`
  now makes from the server's answer about a recorded id.

  c1b2d03a: that confirmation used to resolve the project to confirm against
  via `project_for(root, nil)`, ignoring any `--project` flag already given
  to this same onboard call -- with no `--root`, `root` defaults to
  `File.cwd!()`, so a spec driving this through an in-memory `Environments`
  fixture got confirmation resolved against *this checkout's own real
  project* instead of the fixture's. That produced a mismatched 404 and an
  unwanted re-mint, which is exactly why `project_id` is now threaded all
  the way to `project_for/2` and to the 404 branch's re-mint.

  Fixing the project mismatch surfaced a second bug this file now also
  covers: confirmation used to exchange the resolved project's deploy key
  for an access token via `CmsHarness.Token.exchange/1` -- a real network
  call, logged at `:error` on anything but a clean 200, win or lose.
  `GET /api/harnesses/:id` sits behind `DeployKeyOrOAuth`, which accepts a
  deploy key directly, so `confirm/2` now authenticates with the key itself
  and is pinned to a test plug like every other Req client
  (`CodeMySpec.HttpClientsAreStubbableTest`). With no stub installed --
  true for every existing onboarding spec, none of which deliberately
  exercises this confirmation -- `Req.Test`'s own plug raises, which
  `confirm/2` rescues into the same "could not tell" outcome a real network
  failure already gets. Story 1030's own onboarding criteria (which
  exercise `--project` through a fixture environment, and provision no
  local deploy key for it) are that path's regression coverage.

  The 404-confirms-gone branch re-mints through `mint_and_record/3` ->
  `mint/2` -> `post/3`, which is a *different* Req client still exchanging
  a token via `CmsHarness.Token` -- shared with first-time onboarding
  (`identity/3`'s own no-existing-id fallback), which already depends on
  that exchange succeeding. Giving it the same raw-key treatment as
  `confirm/2` would touch that shared, working path too, which is beyond
  this fix's scope. The 404 branch therefore keeps the exemption `mint/2`
  itself already has: covered by `recorded_id/4`'s own moduledoc note and
  by manual verification, not by a stub here.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias CmsHarness.Onboarding
  alias CodeMySpec.WorkingCopies
  alias Mix.Tasks.Cms.Harness.Onboard

  describe "handle_confirmation/5" do
    test "a 200 trusts the recorded id, regardless of project_id" do
      assert Onboard.handle_confirmation({:ok, %{status: 200}}, "wc-1", nil, nil, "proj-1") ==
               {:ok, "wc-1"}
    end

    test "anything other than a clean 200 or 404 is read as inconclusive, not gone" do
      for other <- [
            {:ok, %{status: 500}},
            {:ok, %{status: 401}},
            {:error, %Req.TransportError{reason: :econnrefused}}
          ] do
        assert Onboard.handle_confirmation(other, "wc-1", nil, nil, "proj-1") == {:ok, "wc-1"},
               "#{inspect(other)} forced a re-mint instead of trusting the file, which " <>
                 "would turn an unreachable server or an unrelated refusal into an " <>
                 "unnecessary new identity"
      end
    end
  end

  describe "confirming a recorded id, driven through the real mix task" do
    setup do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = %{scope | active_project_id: project.id}
      device = device_fixture(scope)

      {:ok, copy} =
        WorkingCopies.issue(scope, nil, device: device.id, root: "/tmp/not-a-real-checkout")

      root = CodeMySpec.TempFile.owned_dir("onboard_identity_confirmation")

      File.write!(
        Path.join(root, ".cms_harness.json"),
        Jason.encode!(%{working_copy_id: copy.id, harness_id: copy.id, project_id: project.id})
      )

      Mix.Task.reenable("cms.harness.onboard")

      %{project: project, copy: copy, root: root}
    end

    test "a 200 from the stubbed server keeps the recorded id, with no real network call", %{
      project: project,
      copy: copy,
      root: root
    } do
      Req.Test.stub(Onboarding, fn conn ->
        assert String.ends_with?(conn.request_path, copy.id)
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      Mix.Task.run("cms.harness.onboard", ["--root", root, "--project", project.id])

      assert %{"working_copy_id" => id} =
               root |> Path.join(".cms_harness.json") |> File.read!() |> Jason.decode!()

      assert id == copy.id,
             "a confirmed-live id was re-minted anyway -- the 200 branch stopped trusting it"
    end
  end
end
