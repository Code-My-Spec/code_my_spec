defmodule CodeMySpec.Analytics.GoogleAnalytics.HTTPAdapter do
  @moduledoc """
  Default HTTP adapter for the GA Measurement Protocol delivery path.
  Uses `Req`. Errors are logged at the call site and dropped — delivery
  is fire-and-forget.
  """

  require Logger

  @spec post(String.t(), map()) :: :ok
  def post(url, payload) do
    case Req.post(url, json: payload, receive_timeout: 5_000) do
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
end
