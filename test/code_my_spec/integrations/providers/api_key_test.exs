defmodule CodeMySpec.Integrations.Providers.ApiKeyTest do
  @moduledoc """
  The real exchange, recorded once and replayed since.

  Everything else about pasting a key is covered by story 1040's spex against a
  `Req.Test` stub, which is right for behaviour — what the page says, what gets
  stored — and useless for the only question this module owns: whether the
  request we build authenticates against the provider. A stub says yes to any
  URL and any header, so the header being wrong, the version being missing, or
  the path being a guess would all pass.

  These ran against Anthropic once, with a real key and with that key one
  character short. The credential is filtered out of both recordings.

  Z.ai is not covered here. Its check is a one-token completion rather than a
  free read, and nobody has a key for it yet — so the shape is written from
  its documentation and remains unproven. That is a gap worth naming rather
  than papering over with a stub that would pass whatever we sent.
  """

  use ExUnit.Case, async: true

  import CodeMySpec.ApiKeyCassetteHelpers

  alias CodeMySpec.Integrations.Providers.ApiKey

  describe "verify/2 against Anthropic" do
    test "a key Anthropic accepts comes back :ok" do
      ReqCassette.with_cassette("anthropic_key_accepted", cassette_opts(), fn plug ->
        with_plug(plug, fn ->
          assert :ok = ApiKey.verify(:anthropic, live_key())
        end)
      end)
    end

    test "a key one character short is refused, and named as refused" do
      ReqCassette.with_cassette("anthropic_key_refused", cassette_opts(), fn plug ->
        with_plug(plug, fn ->
          assert {:error, :rejected} = ApiKey.verify(:anthropic, broken_key())
        end)
      end)
    end
  end

  describe "verify/2 on a provider it does not know" do
    test "is not reachable, rather than being reported as a bad key" do
      assert {:error, {:unreachable, :unknown_provider}} = ApiKey.verify(:github, "irrelevant")
    end
  end
end
