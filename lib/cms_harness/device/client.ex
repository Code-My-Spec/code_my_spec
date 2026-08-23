defmodule CmsHarness.Device.Client do
  @moduledoc """
  The wire between a harness and the server, for announcing a machine — behind
  a seam.

  The same shape `CmsHarness.Project.Transport` gives the channel, and for the
  same reason. That module's own doc says it: `ChannelClient` was previously
  testable only by running drills, so a timer armed at the wrong level was
  learned about slowly. Outbound is the only coupling, and outbound is small.

  Here it is smaller still — one operation — but the seam earns its keep
  immediately. Announcing needs a real credential and a real URL, and a spec
  that runs it unpinned **calls the live server**: writing this without the seam
  produced exactly that, a `POST https://dev.codemyspec.com/api/devices` from a
  test run, with a valid bearer token attached. An unpinned `Req` plus a
  credential is a live call, every time.

  So the default is HTTP and tests swap an implementation that reaches
  `CodeMySpecWeb.Endpoint` in-process — same process, same sandbox, the real
  controller and the real database, and no socket. That is the point: the far
  side under test is the actual server, not a mock of it.

  Read at call time rather than compiled in, so a test can swap it per-case.
  """

  @doc """
  Announce a machine and get back the identity the server issues it, along with
  the copies the server has attached to it.

  `device_id` is what the machine already holds, or nil the first time.

  The reply is a map rather than the bare id it used to be. The exchange is two
  directions: the machine says which of its checkouts it can still see, and the
  server says which checkouts it thinks are on this machine. Only the second
  half lets a restarted harness answer for a copy nobody has worked in since —
  which is the copy most likely to have been deleted.
  """
  @callback announce(device_id :: String.t() | nil, token :: String.t(), attrs :: map()) ::
              {:ok, %{device_id: String.t(), working_copies: %{String.t() => String.t()}}}
              | {:error, term()}

  @doc "The configured client. Defaults to real HTTP."
  @spec impl() :: module()
  def impl, do: Application.get_env(:code_my_spec, :device_client, __MODULE__.Http)
end
