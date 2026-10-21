defmodule CodeMySpec.Devices.RoutineFire do
  @moduledoc """
  Starts a Claude Code cloud session by firing the box's routine (story 1136).

  `POST /v1/claude_code/routines/<id>/fire` with the per-routine token as the
  bearer credential. A 200 answers once the session is created, with a URL to it;
  a 429 is the hourly limit, with `Retry-After`. Never retried here: the person
  is told and decides.

  Experimental on Anthropic's side (research preview).
  """

  alias CodeMySpec.Devices.Device

  @url "https://api.anthropic.com/v1/claude_code/routines"

  @type result ::
          {:ok, %{session_url: String.t() | nil}}
          | {:error, {:rate_limited, non_neg_integer() | nil}}
          | {:error, term()}

  @spec fire(Device.t()) :: result()
  def fire(%Device{fire_routine_id: routine, fire_token: token})
      when is_binary(routine) and routine != "" and is_binary(token) and token != "" do
    request =
      Req.new(
        method: :post,
        url: "#{@url}/#{URI.encode(routine)}/fire",
        headers: [
          {"authorization", "Bearer " <> token},
          {"anthropic-version", "2023-06-01"},
          {"anthropic-beta", "experimental-cc-routine-2026-04-01"}
        ],
        json: %{},
        retry: false,
        receive_timeout: 15_000,
        plug: Application.get_env(:code_my_spec, __MODULE__, [])[:plug]
      )

    request |> Req.request() |> interpret()
  end

  def fire(%Device{}), do: {:error, :no_fire_token}

  defp interpret({:ok, %Req.Response{status: 200, body: body}}),
    do: {:ok, %{session_url: session_url(body)}}

  defp interpret({:ok, %Req.Response{status: 429} = response}),
    do: {:error, {:rate_limited, retry_after(response)}}

  defp interpret({:ok, %Req.Response{status: status}}), do: {:error, {:refused, status}}
  defp interpret({:error, reason}), do: {:error, {:unreachable, reason}}

  defp session_url(%{"claude_code_session_url" => url}) when is_binary(url), do: url
  defp session_url(_body), do: nil

  # Seconds until the limit lifts. The docs do not say whether the header is
  # delta-seconds or an HTTP date, so both are read.
  defp retry_after(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value | _] -> seconds(value)
      [] -> nil
    end
  end

  defp seconds(value) do
    case Integer.parse(value) do
      {seconds, ""} -> max(seconds, 0)
      _ -> from_date(value)
    end
  end

  defp from_date(value) do
    case parse_http_date(value) do
      {:ok, datetime} -> max(DateTime.diff(datetime, DateTime.utc_now()), 0)
      _ -> nil
    end
  end

  defp parse_http_date(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{y, m, d}, {hh, mm, ss}} -> NaiveDateTime.new(y, m, d, hh, mm, ss) |> to_utc()
      :bad_date -> :error
    end
  end

  defp to_utc({:ok, naive}), do: DateTime.from_naive(naive, "Etc/UTC")
  defp to_utc(_), do: :error
end
