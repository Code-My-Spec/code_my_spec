defmodule CodeMySpec.Provisioning.Deploy.UptimeRobot do
  @moduledoc """
  Uptime monitors on the user's own UptimeRobot account.

  Split out of `Deploy` because it is a separate provider with its own
  credential and failure modes; `Deploy` owns the deploy sequence, this owns
  talking to UptimeRobot.

  ## Why an external monitor rather than polling ourselves

  The point of the monitor is to notice when Sam's site stops answering — and
  a check that runs inside the thing being watched cannot report on its own
  outage. An external monitor survives the platform being down, which is
  precisely the case that matters.

  ## The API is form-encoded and answers 200 on failure

  UptimeRobot's v2 API takes `application/x-www-form-urlencoded`, not JSON,
  and signals failure with `stat: "fail"` in a 200 body. Matching on HTTP
  status alone would read every failure as a success.
  """

  @api_base "https://api.uptimerobot.com/v2"

  # 1 = HTTP(S) monitor in UptimeRobot's vocabulary.
  @http_monitor_type 1

  @type error :: {:error, :uptime_robot_not_configured} | {:error, term()}

  @doc """
  Ensure a monitor exists for each host, alerting `notify`.

  Idempotent: an existing monitor for the same URL is reused rather than
  duplicated, so a retried monitoring step does not produce two alerts per
  outage.
  """
  @spec ensure_monitors([String.t()], String.t(), keyword()) :: {:ok, [map()]} | error()
  def ensure_monitors(hosts, notify, opts \\ []) do
    with {:ok, existing} <- list_monitors(),
         {:ok, alert_contact_id} <- alert_contact_id(notify, opts) do
      hosts
      |> Enum.reduce_while({:ok, []}, fn host, {:ok, acc} ->
        case ensure_monitor(host, existing, alert_contact_id) do
          {:ok, monitor} -> {:cont, {:ok, [monitor | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, monitors} -> {:ok, Enum.reverse(monitors)}
        error -> error
      end
    end
  end

  defp ensure_monitor(host, existing, alert_contact_id) do
    url = "https://#{host}"

    case Enum.find(existing, &(&1["url"] == url)) do
      nil -> create_monitor(host, url, alert_contact_id)
      monitor -> {:ok, monitor}
    end
  end

  defp create_monitor(host, url, alert_contact_id) do
    post("/newMonitor", %{
      "friendly_name" => host,
      "url" => url,
      "type" => @http_monitor_type,
      "alert_contacts" => alert_contact_id
    })
    |> case do
      {:ok, %{"monitor" => monitor}} -> {:ok, monitor}
      {:ok, body} -> {:ok, body}
      {:error, _} = error -> error
    end
  end

  @doc "Every monitor on the account."
  @spec list_monitors() :: {:ok, [map()]} | error()
  def list_monitors do
    case post("/getMonitors", %{}) do
      {:ok, %{"monitors" => monitors}} when is_list(monitors) -> {:ok, monitors}
      {:ok, _} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  # The notification target is passed through as an alert-contact id. When the
  # caller gives an id we use it; a bare address cannot be turned into one
  # without the account's contact list, so that is looked up rather than
  # guessed.
  defp alert_contact_id(notify, opts) do
    case Keyword.get(opts, :alert_contact_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> find_alert_contact(notify)
    end
  end

  defp find_alert_contact(notify) do
    case post("/getAlertContacts", %{}) do
      {:ok, %{"alert_contacts" => contacts}} when is_list(contacts) ->
        contacts
        |> Enum.find(&(&1["value"] == notify))
        |> case do
          nil -> {:error, {:no_alert_contact_for, notify}}
          contact -> {:ok, to_string(contact["id"])}
        end

      {:ok, _} ->
        {:error, {:no_alert_contact_for, notify}}

      {:error, _} = error ->
        error
    end
  end

  defp post(path, params) do
    case api_key() do
      {:ok, key} ->
        [
          method: :post,
          url: @api_base <> path,
          form: Map.merge(%{"api_key" => key, "format" => "json"}, params)
        ]
        |> Keyword.merge(plug_opt())
        |> Req.request()
        |> handle_response()

      :error ->
        {:error, :uptime_robot_not_configured}
    end
  end

  # `stat: "fail"` arrives with a 200, so the body decides, not the status.
  defp handle_response({:ok, %Req.Response{body: %{"stat" => "fail"} = body}}),
    do: {:error, {:uptime_robot_error, body["error"] || body}}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:uptime_robot_error, status, body}}

  defp handle_response({:error, reason}), do: {:error, reason}

  defp api_key do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:api_key] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> :error
    end
  end

  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:plug] do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
