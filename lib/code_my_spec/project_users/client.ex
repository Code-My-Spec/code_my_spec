defmodule CodeMySpec.ProjectUsers.Client do
  @moduledoc """
  Hand-written Req client for a target application's CodeMySpec users endpoint
  (`GET {client_api_url}/api/cms/users`), authenticated with the project's
  deploy key as a Bearer token.

  Returns an in-memory `Page` — nothing is persisted. In tests a `Req.Test`
  plug is injected via the `:project_users_req_plug` application env so the
  outbound call is intercepted without hitting the network.
  """

  alias CodeMySpec.ProjectUsers.{Page, User}

  @path "/api/cms/users"

  @spec list_registered_users(String.t(), String.t(), pos_integer()) ::
          {:ok, Page.t()} | {:error, :unauthorized | :unreachable | term()}
  def list_registered_users(client_api_url, deploy_key, page) do
    url = client_api_url |> URI.parse() |> URI.merge(@path) |> URI.to_string()

    [
      url: url,
      params: [page: page],
      headers: [{"authorization", "Bearer #{deploy_key}"}],
      decode_json: [keys: :strings],
      # Fail fast on a user-facing read — don't hang the LiveView retrying an
      # unreachable target; surface the error and let the user retry.
      retry: false
    ]
    |> Req.new()
    |> attach_test_plug()
    |> Req.get()
    |> handle_response()
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}), do: {:ok, to_page(body)}
  defp handle_response({:ok, %Req.Response{status: 401}}), do: {:error, :unauthorized}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:unexpected_status, status, body}}

  defp handle_response({:error, %Req.TransportError{}}), do: {:error, :unreachable}
  defp handle_response({:error, reason}), do: {:error, reason}

  defp to_page(%{"data" => data} = body) do
    %Page{
      users: Enum.map(data, &to_user/1),
      page: body["page"] || 1,
      page_size: body["page_size"] || length(data),
      total: body["total"] || length(data)
    }
  end

  defp to_user(%{"email" => email} = row) do
    %User{email: email, registered_at: parse_datetime(row["registered_at"])}
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp attach_test_plug(req) do
    case Application.get_env(:code_my_spec, :project_users_req_plug) do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end
end
