defmodule CodeMySpec.Analytics.GoogleAnalytics.HTTPAdapter do
  @moduledoc """
  Default HTTP adapter for the GA Measurement Protocol delivery path.
  Uses `Req`. Errors are logged at the call site and dropped — delivery
  is fire-and-forget.
  """

  require Logger

  @spec post(String.t(), map()) :: :ok
  def post(url, payload) do
    req_opts = [json: payload, receive_timeout: 5_000] |> Keyword.merge(plug_opt())

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("GA Measurement Protocol non-2xx: status=#{status} body=#{inspect(body)}")
        :ok

      {:error, reason} ->
        Logger.warning("GA Measurement Protocol HTTP error: #{inspect(reason)}")
        :ok
    end
  end

  # Tests inject a ReqCassette plug via Application.put_env so HTTP can be
  # recorded/replayed against a real cassette without hitting GA.
  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, []) |> Keyword.get(:plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
