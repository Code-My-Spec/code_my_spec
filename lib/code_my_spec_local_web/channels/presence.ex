defmodule CodeMySpecLocalWeb.Presence do
  @moduledoc """
  Presence for the local endpoint's harness channel. A lane is "registered for
  role X" exactly while its channel is joined — this is the Story-704 heartbeat
  that replaces the polled subagent-TTL registry.

  Runs on the shared `CodeMySpec.PubSub`, so it is available wherever the local
  endpoint is (the `cms` CLI and the test env).
  """
  use Phoenix.Presence,
    otp_app: :code_my_spec,
    pubsub_server: CodeMySpec.PubSub
end
