defmodule CodeMySpecWeb.SourceGitController do
  @moduledoc ~s(Read-only Git smart HTTP for a project source repository.)
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Accounts
  alias CodeMySpec.Integrations
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  require Logger

  @max_request_bytes 16_000_000

  def refs(conn, %{~s(project_id) => id, ~s(kind) => kind, ~s(service) => ~s(git-upload-pack)}) do
    proxy(conn, id, kind, :get, ~s(info/refs?service=git-upload-pack), nil)
  end

  def refs(conn, _params), do: send_resp(conn, :bad_request, ~s(Unsupported Git service))

  def upload_pack(conn, %{~s(project_id) => id, ~s(kind) => kind}) do
    case read_pack(conn, <<>>) do
      {:ok, body, conn} -> proxy(conn, id, kind, :post, ~s(git-upload-pack), body)
      {:error, conn} -> send_resp(conn, :request_entity_too_large, ~s(Git request too large))
    end
  end

  defp proxy(conn, id, kind, method, path, body) do
    scope = conn.assigns.current_scope

    with false <- Map.has_key?(conn.assigns, :box_device),
         {:ok, project} <- Projects.get_project_for_user(scope, id),
         {:ok, repo} <- repo_url(project, kind),
         {:ok, token} <- account_github_token(scope, project.account_id),
         {:ok, response} <- request(conn, method, repo <> ~s(/) <> path, body, token) do
      send_git_response(conn, method, response)
    else
      {:error, :not_found} -> send_resp(conn, :not_found, ~s(Project not found))
      {:error, :invalid_repo} -> send_resp(conn, :not_found, ~s(Git source unavailable))
      _ -> send_resp(conn, :bad_gateway, ~s(Git source unavailable))
    end
  end

  # A device grant identifies an account member, who may never have connected
  # GitHub. Use a connection held by the project's account instead. Prefer its
  # owner, then another connected member, so the choice is stable.
  defp account_github_token(scope, account_id) do
    scope
    |> Accounts.list_account_members(account_id)
    |> Enum.sort_by(fn member -> {member.role != :owner, member.inserted_at, member.id} end)
    |> Enum.find_value({:error, :not_found}, fn member ->
      member_scope = %Scope{user: member.user, user_id: member.user_id}

      case Integrations.get_integration(member_scope, :github) do
        {:ok, _integration} -> Integrations.fetch_access_token(member_scope, :github)
        {:error, :not_found} -> nil
      end
    end)
  end

  defp send_git_response(conn, method, %{status: status, body: body} = response)
       when status in 200..299 and is_binary(body) do
    conn
    |> put_resp_header(
      "content-type",
      response_header(response, "content-type", git_content_type(method))
    )
    |> put_response_header(response, "content-encoding")
    |> send_resp(status, body)
  end

  defp send_git_response(conn, _method, %{status: status, body: body}) do
    prefix = if is_binary(body), do: binary_part(body, 0, min(byte_size(body), 64)), else: <<>>

    Logger.warning(
      "Git source upstream returned HTTP #{status}; body prefix (hex): #{Base.encode16(prefix)}"
    )

    send_resp(conn, :bad_gateway, ~s(Git source unavailable))
  end

  defp response_header(response, name, default) do
    response |> Req.Response.get_header(name) |> List.first() || default
  end

  defp put_response_header(conn, response, name) do
    Enum.reduce(Req.Response.get_header(response, name), conn, fn value, conn ->
      put_resp_header(conn, name, value)
    end)
  end

  defp git_content_type(:get), do: ~s(application/x-git-upload-pack-advertisement)
  defp git_content_type(:post), do: ~s(application/x-git-upload-pack-result)

  defp repo_url(project, kind) when kind in [~s(code), ~s(docs)] do
    value = if kind == ~s(code), do: project.code_repo, else: project.docs_repo

    case value do
      ~s(git@github.com:) <> path -> github_path(path)
      ~s(https://github.com/) <> path -> github_path(path)
      _ -> {:error, :invalid_repo}
    end
  end

  defp repo_url(_project, _kind), do: {:error, :invalid_repo}

  defp github_path(path) do
    path = String.trim_trailing(path, ~s(.git))

    if Regex.match?(~r{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$}, path) and
         not String.contains?(path, ~s(..)) do
      {:ok, ~s(https://github.com/) <> path <> ~s(.git)}
    else
      {:error, :invalid_repo}
    end
  end

  defp request(conn, method, url, body, token) do
    headers = [
      {~s(authorization), ~s(Basic ) <> Base.encode64(~s(x-access-token:) <> token)},
      {~s(user-agent), ~s(CodeMySpec)}
    ]

    headers = forward_headers(conn, headers, ["accept", "git-protocol"])

    headers =
      if method == :post do
        [
          {"content-type", "application/x-git-upload-pack-request"}
          | forward_headers(conn, headers, ["content-encoding"])
        ]
      else
        headers
      end

    options = [
      method: method,
      url: url,
      body: body,
      headers: headers,
      raw: true,
      redirect: false,
      retry: false,
      receive_timeout: 120_000
    ]

    config = Application.get_env(:code_my_spec, __MODULE__, [])

    options =
      case {config[:adapter], config[:plug]} do
        {nil, nil} -> options
        {nil, plug} -> Keyword.put(options, :plug, plug)
        {adapter, _plug} -> Keyword.put(options, :adapter, adapter)
      end

    Req.request(options)
  end

  defp forward_headers(conn, headers, names) do
    Enum.reduce(names, headers, fn name, headers ->
      Enum.reduce(Plug.Conn.get_req_header(conn, name), headers, fn value, headers ->
        [{name, value} | headers]
      end)
    end)
  end

  defp read_pack(conn, body) when byte_size(body) > @max_request_bytes, do: {:error, conn}

  defp read_pack(conn, body) do
    case Plug.Conn.read_body(conn, length: 1_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} ->
        combined = body <> chunk

        if byte_size(combined) > @max_request_bytes,
          do: {:error, conn},
          else: {:ok, combined, conn}

      {:more, chunk, conn} ->
        read_pack(conn, body <> chunk)

      {:error, _reason} ->
        {:error, conn}
    end
  end
end
