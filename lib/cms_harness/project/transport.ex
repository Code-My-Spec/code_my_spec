defmodule CmsHarness.Project.Transport do
  @moduledoc """
  The wire, behind a seam.

  `ChannelClient` is the most delicate module in this harness — reconnects,
  reply correlation, join refusal, the read-model refresh — and until now none of
  it could be tested without a live Slipstream socket and a server on the other
  end. So it was tested by running drills, which is a slow way to learn that a
  timer was armed at the wrong level.

  The coupling turned out to be small. Inbound is already testable: every
  `handle_*` callback is an ordinary function a test can call with a socket it
  built. Only *outbound* needed a seam, and outbound is three operations.

  Note what is deliberately not abstracted: `Slipstream.Socket` itself. A test
  builds one directly and asserts on the assigns, which is simpler than
  inventing a socket type and keeps the tests honest about the real struct the
  production code manipulates.
  """

  @type socket :: term()
  @type topic :: String.t()

  @doc "Send an event, expecting a reply the caller will correlate by ref."
  @callback push(socket(), topic(), event :: String.t(), payload :: map(), timeout()) ::
              {:ok, reference()} | {:error, term()}

  @doc "Join a topic. Returns the socket; refusal arrives via `handle_topic_close/3`."
  @callback join(socket(), topic(), params :: map()) :: socket()

  @doc """
  Drop the connection. Returns the socket; `handle_disconnect/2` follows.

  Used to recover a channel the server no longer has — see `ChannelClient`.
  """
  @callback disconnect(socket()) :: socket()

  @doc """
  The configured transport.

  Defaults to the real one; tests set `:transport` to a recorder. Read at call
  time rather than compiled in, so a test can swap it per-case.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:code_my_spec, :harness_transport, __MODULE__.Slipstream)
end
