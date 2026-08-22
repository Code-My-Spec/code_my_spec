defmodule CmsHarness.Web.UpstreamStatusTest do
  @moduledoc """
  An upstream status this process has never heard of must not become a 500 from
  this process.

  Anthropic answered 529 "overloaded". `put_status/2` raises
  `ArgumentError: unknown status code 529` for anything outside Plug's table, so
  the proxy crashed and the agent was told:

      The CodeMySpec harness failed to handle this hook (Internal Server Error).
      This is the local harness process, not the CodeMySpec server. Check its log.

  — which sent the reader to `localhost:4004` for a problem that was upstream,
  transient, and already retryable. A proxy converting somebody else's temporary
  answer into its own hard failure is the worst version of this: the message is
  confident and points the wrong way.

  Two mechanisms, deliberately. 529 is *configured*, because it is a code we
  expect and `config :plug, :statuses` is the documented home for that. The
  guard in the controller is for the ones we do not expect, because an upstream
  can return anything and the failure mode is silent until it is not.
  """
  use ExUnit.Case, async: true

  alias Plug.Conn.Status

  describe "codes we expect" do
    test "529 has a reason phrase, so it can be forwarded as itself" do
      assert Status.reason_phrase(529) == "Overloaded", """
      529 is not configured. `config :plug, :statuses` in config/config.exs is
      what stops Anthropic's overload answer becoming a harness 500.
      """
    end

    test "configuring it did not disturb the ordinary ones" do
      assert Status.reason_phrase(200) == "OK"
      assert Status.reason_phrase(502) == "Bad Gateway"
    end
  end

  describe "codes we do not expect" do
    # The controller's `forwardable/1` is private, so this asserts the property
    # it relies on rather than reaching in: Plug raises, and it raises
    # `ArgumentError`, which is what the rescue is written for. If Plug ever
    # changed that to returning nil, the guard would stop working and nothing
    # else here would notice.
    test "an unconfigured code raises ArgumentError, which is what the guard catches" do
      assert_raise ArgumentError, fn -> Status.reason_phrase(599) end
    end
  end
end
