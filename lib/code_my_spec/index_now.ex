defmodule CodeMySpec.IndexNow do
  @moduledoc """
  Notifies search engines of new/updated URLs via the IndexNow protocol.
  Supports Bing, Yandex, and Naver.
  """
  require Logger

  @api_url "https://api.indexnow.org/IndexNow"

  def notify(urls) when is_list(urls) and urls != [] do
    key = key()
    host = host()

    if key && host do
      body =
        Jason.encode!(%{
          host: host,
          key: key,
          keyLocation: "https://#{host}/#{key}.txt",
          urlList: urls
        })

      Task.start(fn ->
        case Req.post(@api_url, body: body, headers: [{"content-type", "application/json"}]) do
          {:ok, %{status: status}} when status in 200..299 ->
            Logger.info("IndexNow: submitted #{length(urls)} URLs (#{status})")

          {:ok, %{status: status, body: body}} ->
            Logger.warning("IndexNow: unexpected status #{status}: #{inspect(body)}")

          {:error, reason} ->
            Logger.warning("IndexNow: request failed: #{inspect(reason)}")
        end
      end)

      :ok
    else
      Logger.debug("IndexNow: skipped (key or host not configured)")
      :skip
    end
  end

  def notify(_), do: :ok

  def notify_content_sync(content_list) when is_list(content_list) do
    base_url = CodeMySpec.PublicUrl.base()

    urls =
      Enum.map(content_list, fn content ->
        prefix = content_prefix(content.content_type)
        "#{base_url}#{prefix}#{content.slug}"
      end)

    notify(urls)
  end

  def key do
    Application.get_env(:code_my_spec, :indexnow_key)
  end

  defp host do
    case CodeMySpec.PublicUrl.base() do
      "https://" <> host -> host
      "http://" <> host -> host
      _ -> nil
    end
  end

  defp content_prefix(:blog), do: "/blog/"
  defp content_prefix(:page), do: "/pages/"
  defp content_prefix(:documentation), do: "/documentation/"
  defp content_prefix(:landing), do: "/landing/"
  defp content_prefix(_), do: "/"
end
