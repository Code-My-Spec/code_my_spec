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

  Z.ai now has a real (but unfunded) test key at `~/.codemyspec/zai_test_key`.
  Its own check asks for `glm-5.3`, the model agents actually run on, so this
  account's real 429 (insufficient balance) is the real answer that code has
  to handle, not one avoided by asking for a cheaper model instead. The free
  `glm-4.5-flash` only appears below to record what a real 200 looks like,
  which nothing here could otherwise see with an account that has no balance.
  """

  # with_plug/2 temporarily changes the node-wide ApiKey request config.
  # Run after async tests so their Req.Test stubs cannot see a cassette plug.
  use ExUnit.Case, async: false

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

  describe "verify/2 against Z.ai" do
    test "a real key with nothing to spend is accepted, not rejected or unexpected" do
      ReqCassette.with_cassette("zai_key_no_balance", cassette_opts(), fn plug ->
        with_plug(plug, fn ->
          assert {:ok, :no_balance} = ApiKey.verify(:zai, zai_live_key())
        end)
      end)
    end

    test "the real success shape, recorded against the free glm-4.5-flash" do
      ReqCassette.with_cassette("zai_key_accepted", cassette_opts(), fn plug ->
        with_plug(plug, fn ->
          response =
            Req.request(
              method: :post,
              url: "https://api.z.ai/api/paas/v4/chat/completions",
              headers: [{"authorization", "Bearer " <> zai_live_key()}],
              json: %{
                model: "glm-4.5-flash",
                messages: [%{role: "user", content: "hi"}],
                max_tokens: 1
              },
              plug: plug,
              receive_timeout: 15_000
            )

          assert {:ok, %Req.Response{status: 200}} = response
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
