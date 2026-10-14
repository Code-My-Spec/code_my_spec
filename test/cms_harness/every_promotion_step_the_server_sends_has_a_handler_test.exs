defmodule CmsHarness.EveryPromotionStepTheServerSendsHasAHandlerTest do
  @moduledoc """
  Every promotion step the server asks a harness to run has a handler there.

  The gate's asset build landed with only its server half: `Promotion.Runner`
  sent `promotion_build_assets`, the harness answered "this harness does not
  implement promotion_build_assets", and every batch after it was ejected
  (2026-10-13). The gate cannot catch this — it runs on the harness it would be
  asking — so the two halves are checked against each other here.
  """
  use ExUnit.Case, async: true

  @runner "lib/code_my_spec/promotion/runner.ex"
  @handler "lib/cms_harness/project/channel_client.ex"

  test "each promotion_* op the runner sends is an apply_promotion clause on the harness" do
    sent = Regex.scan(~r/"(promotion_[a-z_]+)"/, File.read!(@runner)) |> Enum.map(&List.last/1)
    handled = File.read!(@handler)

    assert sent != [], "found no promotion ops in #{@runner}; the pattern is stale"

    missing =
      sent
      |> Enum.uniq()
      |> Enum.reject(&Regex.match?(~r/apply_promotion\(\s*"#{&1}"/, handled))

    assert missing == [],
           "the server sends these but the harness has no apply_promotion clause for them, " <>
             "so every batch reaching them is ejected: #{inspect(missing)}"
  end
end
