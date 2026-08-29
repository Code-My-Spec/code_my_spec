defmodule CodeMySpec.Research.Http do
  @moduledoc """
  The one place a request to the open web is built.

  Every call out of `Research` goes through here so that the `Req.Test` plug is
  attached in exactly one place. Async tests stub the plug rather than setting
  application env — see `reference_req_test_stub_for_async_tests`; a client that
  builds its own `Req` behind this module's back is a live HTTP call in the
  suite, which is how the test suite once posted to real Google Analytics.
  """

  @default_timeout to_timeout(second: 15)

  @doc """
  A `Req.Request` for `options`, carrying the configured plug and timeout.

  `receive_timeout` is stated rather than left to Req's 15-second default
  because a fetch of a slow page and a call to a search API have no business
  sharing a deadline with a small JSON POST — and because the intake shaper had
  exactly this bug: a 15-second default silently truncating calls that took 15.0
  seconds from the wrong continent.
  """
  @spec new(keyword()) :: Req.Request.t()
  def new(options) do
    {timeout, options} = Keyword.pop(options, :timeout, timeout())

    options
    |> Keyword.put_new(:receive_timeout, timeout)
    |> Keyword.put_new(:redirect, true)
    |> Keyword.put_new(:retry, false)
    |> Req.new()
    |> attach_plug()
  end

  @doc "Everything under `config :code_my_spec, CodeMySpec.Research`."
  @spec config() :: keyword()
  def config, do: Application.get_env(:code_my_spec, CodeMySpec.Research, [])

  @doc "A single key from that config."
  @spec config(atom(), term()) :: term()
  def config(key, default \\ nil), do: Keyword.get(config(), key, default)

  @doc "How long any one request may take."
  @spec timeout() :: pos_integer()
  def timeout, do: config(:timeout, @default_timeout)

  defp attach_plug(req) do
    case config(:plug) do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end
end
