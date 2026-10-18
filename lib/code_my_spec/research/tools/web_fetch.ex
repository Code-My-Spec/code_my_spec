defmodule CodeMySpec.Research.Tools.WebFetch do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Research
  alias CodeMySpec.Research.Tools

  @impl true
  def name, do: "web_fetch"

  @impl true
  def description do
    """
    Read a web page as Markdown.

    Handles the shapes that are worth handling: GitHub file views are read as the
    raw file rather than the surrounding application, JSON is pretty-printed, and
    ordinary pages are stripped of navigation and converted to Markdown.

    Reddit is refused rather than fetched — it needs an OAuth app now, and what
    comes back without one is a login wall that converts to Markdown perfectly
    and says nothing.
    """
  end

  @impl true
  def params do
    %{
      url: {:required, {:meta, :string, [description: "The http(s) URL to read"]}},
      max_output:
        {:meta, :integer,
         [description: "Bytes of content to return. Default 100000. Truncation is reported"]}
    }
  end

  @impl true
  def call(%{url: url} = params, context) do
    with {:ok, _scope} <- Tools.scoped(context) do
      case Research.fetch(url, opts(params)) do
        {:ok, page} -> {:ok, format(page)}
        {:error, reason} -> {:error, message(url, reason)}
      end
    end
  end

  defp opts(%{max_output: max}) when is_integer(max) and max > 0, do: [max_output: max]
  defp opts(_params), do: []

  defp format(page) do
    [header(page), page.content, footer(page)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp header(page) do
    [
      page.title && "# #{page.title}",
      "Source: #{page.fetched_url}",
      # Only when it differs: a GitHub blob URL read as a raw file, or a
      # redirect that landed somewhere else.
      page.fetched_url != page.url && "Requested: #{page.url}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp footer(%{truncated: true}),
    do: "[Truncated. Raise max_output to read further, or fetch a more specific URL.]"

  defp footer(_page), do: ""

  defp message(_url, {:unsupported_scheme, scheme}),
    do: "#{scheme}: URLs are not fetchable. Only http and https are."

  defp message(url, :invalid_url), do: "#{inspect(url)} is not a URL."

  defp message(_url, :reddit_requires_oauth) do
    "Reddit cannot be read without a registered OAuth app — every public door " <>
      "(www, old, and the .json endpoint) now answers a login wall or a 302. " <>
      "Nothing was fetched, because what comes back is the sign-up page rather " <>
      "than the thread. Look for the same discussion somewhere quotable."
  end

  defp message(url, {:status, 404, _detail}), do: "#{url} answered 404."

  defp message(url, {:status, status, detail}) when status in [401, 403],
    do: "#{url} answered #{status} — it needs credentials this tool does not have. #{detail}"

  defp message(url, {:status, status, detail}), do: "#{url} answered #{status}. #{detail}"
  defp message(url, reason) when is_binary(reason), do: "Could not read #{url}: #{reason}"
  defp message(url, reason), do: "Could not read #{url}: #{inspect(reason)}"
end
