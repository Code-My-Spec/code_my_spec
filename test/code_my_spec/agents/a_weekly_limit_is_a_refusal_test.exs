defmodule CodeMySpec.Agents.AWeeklyLimitIsARefusalTest do
  @moduledoc """
  claude's weekly-limit failure is a provider refusal with a reset time, so the
  loop stops waking the agent into it until then.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.ProviderRefusal

  @now ~U[2026-09-30 20:00:00Z]
  @weekly "claude exec failed with status 1: You've hit your weekly limit · resets Oct 3 at 6pm (America/Toronto)"

  test "the weekly limit is a refusal" do
    assert %{provider_refusal: reason} = ProviderRefusal.read(@weekly, @now)
    assert reason =~ "weekly limit"
  end

  test "its reset is the retry time" do
    assert %{provider_retry_at: ~U[2026-10-03 18:00:00.000000Z]} =
             ProviderRefusal.read(@weekly, @now)
  end

  test "a reset earlier in the year than now is next year's" do
    text = "You've hit your weekly limit · resets Jan 2 at 9:30am (UTC)"

    assert %{provider_retry_at: ~U[2027-01-02 09:30:00.000000Z]} =
             ProviderRefusal.read(text, @now)
  end

  test "a crash that is not a limit is still not a refusal" do
    assert ProviderRefusal.read("claude exec failed with status 1: segmentation fault", @now) ==
             nil
  end
end
