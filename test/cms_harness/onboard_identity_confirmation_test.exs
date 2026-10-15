defmodule CmsHarness.OnboardIdentityConfirmationTest do
  @moduledoc """
  45cb6b07: `Staffing.offboard/2` deletes the server's working-copy row but
  never touches the checkout's own files, so a recorded `working_copy_id`
  used to be trusted on faith forever -- a checkout re-onboarded after an
  explicit offboard stayed invisible to the server with nothing anywhere
  saying so. `Onboard.handle_confirmation/4` is the decision `identity/3`
  now makes from the server's answer about a recorded id.

  The 404-confirms-gone branch re-mints for real (`mint_and_record/2`, a
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

  describe "handle_confirmation/4" do
    test "a 200 trusts the recorded id" do
      assert Onboard.handle_confirmation({:ok, %{status: 200}}, "wc-1", nil, nil) ==
               {:ok, "wc-1"}
    end

    test "anything other than a clean 200 or 404 is read as inconclusive, not gone" do
      for other <- [
            {:ok, %{status: 500}},
            {:ok, %{status: 401}},
            {:error, %Req.TransportError{reason: :econnrefused}}
          ] do
        assert Onboard.handle_confirmation(other, "wc-1", nil, nil) == {:ok, "wc-1"},
               "#{inspect(other)} forced a re-mint instead of trusting the file, which " <>
                 "would turn an unreachable server or an unrelated refusal into an " <>
                 "unnecessary new identity"
      end
    end
  end
end
