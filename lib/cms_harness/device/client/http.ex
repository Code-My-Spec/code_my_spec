defmodule CmsHarness.Device.Client.Http do
  @moduledoc """
  Announce over HTTP — what a real harness does.

  `POST /api/devices`, bearer credential, and the id back. Deliberately plain:
  the machine has no project yet, so there is no channel to carry this, and the
  route it calls is the same shape `mix cms.harness.onboard` already uses to
  mint a working copy id.
  """

  @behaviour CmsHarness.Device.Client

  alias CmsHarness.Config

  @impl true
  def announce(device_id, token, attrs) do
    body =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> put_present("device_id", device_id)

    [
      url: Path.join(Config.server_url(), "/api/devices"),
      json: body,
      headers: [{"authorization", "Bearer #{token}"}],
      receive_timeout: 10_000
    ]
    |> Keyword.merge(plug_opt())
    |> Req.post()
    |> issued()
  end

  # Pinned in test, unset everywhere else. `HttpClientsAreStubbableTest` exists
  # because an unset plug makes a real request the moment a credential is
  # present and logs nothing when it succeeds — which is precisely what this
  # client did on its first run, POSTing to the live server from a spec.
  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, []) |> Keyword.get(:plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end

  defp issued({:ok, %{status: 200, body: %{"device_id" => id}}}) when is_binary(id),
    do: {:ok, id}

  defp issued({:ok, %{status: status, body: body}}), do: {:error, {status, body}}
  defp issued({:error, reason}), do: {:error, reason}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
