defmodule CodeMySpecWeb.ImageUrl do
  @moduledoc """
  Builds URLs for static content images.

  When `IMAGES_HOST` is set (e.g. `https://images.codemyspec.com`), images are
  served from that host directly (typically a CDN-fronted object store like R2).
  When unset, images fall back to the app-served `/images/...` path so local
  development continues to work.
  """

  @doc """
  Returns a URL for `filename` (e.g. `"hero-foo.png"`).

  Pass `base_url` (the request's scheme+host) when the result must be absolute,
  e.g. for `og:image` meta tags. Omit it when a relative URL is fine.
  """
  def image_url(filename, base_url \\ nil) do
    case configured_host() do
      host when is_binary(host) and host != "" ->
        "#{host}/#{filename}"

      _ ->
        if base_url, do: "#{base_url}/images/#{filename}", else: "/images/#{filename}"
    end
  end

  defp configured_host, do: Application.get_env(:code_my_spec, :images_host)
end
