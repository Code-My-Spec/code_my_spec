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
  the way to `project_for/2` and to the 404 branch's re-mint. Story 1030's
  onboarding criteria (which exercise `--project` through a fixture
  environment) are this fix's real regression coverage.

  The 404-confirms-gone branch re-mints for real (`mint_and_record/3`, a
  live `Req.post`), so it is not driven here -- `Mix.Tasks.Cms.Harness.Onboard`
  is listed in `CodeMySpec.HttpClientsAreStubbableTest` as exempt because mix
  tasks are not run by this suite at all. What is safely testable without any
  network call is that a confirmed-live id is trusted, and that anything
  other than a clean 200 or 404 -- an unreachable server, a non-2xx the
  endpoint has never returned, a raised `Req.TransportError` wrapped as
  `{:error, _}` -- is read as "could not tell" rather than "gone", so a
  transient hiccup never forces an unnecessary re-mint.
  """
  use ExUnit.Case, async: true

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
end
