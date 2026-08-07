defmodule CmsHarness.Project.Transport.Test do
  @moduledoc """
  Records what the client tried to send, instead of sending it.

  Every push is delivered to the test process as
  `{:transport_push, topic, event, payload, ref}` and also returned as a ref the
  client can correlate, so a test can drive a reply through `handle_reply/3` and
  watch the whole exchange without a socket, a server, or a network.

  Deliberately a message rather than an agent: assertions read as
  `assert_receive {:transport_push, _, "observations", payload, _}`, which fails
  with the actual payload in the message rather than a diff against a
  hand-maintained recorder.
  """

  @behaviour CmsHarness.Project.Transport

  @impl true
  def push(_socket, topic, event, payload, _timeout) do
    ref = make_ref()
    send(owner(), {:transport_push, topic, event, payload, ref})
    {:ok, ref}
  end

  @impl true
  def join(socket, topic, params) do
    send(owner(), {:transport_join, topic, params})
    socket
  end

  @impl true
  def disconnect(socket) do
    send(owner(), {:transport_disconnect, socket.assigns[:topic]})
    socket
  end

  # The test process, set by the case. Falls back to self() so a stray call in
  # a non-test context is inert rather than a crash.
  defp owner, do: Application.get_env(:code_my_spec, :harness_transport_owner, self())
end
