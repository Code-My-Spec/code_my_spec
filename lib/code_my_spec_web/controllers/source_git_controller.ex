defmodule CodeMySpecWeb.SourceGitController do
  @moduledoc ~s(Read-only Git smart HTTP for a project source repository.)
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Integrations
  alias CodeMySpec.Projects

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
         {:ok, project} <- Projects.get_project(scope, id),
         {:ok, repo} <- repo_url(project, kind),
         {:ok, token} <- Integrations.fetch_access_token(scope, :github),
         {:ok, response} <- request(method, repo <> ~s(/) <> path, body, token) do
      if response.status in 200..299 and is_binary(response.body) do
        content_type =
          case method do
            :get -> ~s(application/x-git-upload-pack-advertisement)
            :post -> ~s(application/x-git-upload-pack-result)
          end

        conn
        |> put_resp_header("content-type", content_type)
        |> send_resp(response.status, response.body)
      else
        send_resp(conn, :bad_gateway, ~s(Git source unavailable))
      end
    else
      {:error, :not_found} -> send_resp(conn, :not_found, ~s(Project not found))
      {:error, :invalid_repo} -> send_resp(conn, :not_found, ~s(Git source unavailable))
      _ -> send_resp(conn, :bad_gateway, ~s(Git source unavailable))
    end
  end

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

  defp request(method, url, body, token) do
    headers = [
      {~s(authorization), ~s(Basic ) <> Base.encode64(~s(x-access-token:) <> token)},
      {~s(accept), ~s(*/*)},
      {~s(user-agent), ~s(CodeMySpec)}
    ]

    headers =
      if method == :post,
        do: [{~s(content-type), ~s(application/x-git-upload-pack-request)} | headers],
        else: headers

    options = [
      method: method,
      url: url,
      body: body,
      headers: headers,
      decode_body: false,
      redirect: false,
      retry: false,
      receive_timeout: 120_000
    ]

    options =
      case Application.get_env(:code_my_spec, :source_git_plug) do
        nil -> options
        plug -> Keyword.put(options, :plug, plug)
      end

    Req.request(options)
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
