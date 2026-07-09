defmodule CodeMySpecWeb.MailImageController do
  @moduledoc """
  Streams a remote email image through our server so it renders under the app's
  own origin (CSP-clean) without leaking the reader's IP to the sender. Only
  URLs we signed into email HTML are accepted (`ImageProxy.verify/1`); the fetch
  itself is guarded against private hosts, non-images and oversized bodies.

  On any failure we return a 1×1 transparent GIF rather than a broken-image
  icon, so a dead or hostile image just disappears.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Mail.ImageProxy

  # 1×1 transparent GIF.
  @pixel <<71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 0, 0, 0, 255, 255, 255, 33, 249, 4, 1,
           0, 0, 0, 0, 44, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 1, 68, 0, 59>>

  def show(conn, %{"u" => token}) do
    with {:ok, url} <- ImageProxy.verify(token),
         {:ok, content_type, body} <- ImageProxy.fetch(url) do
      conn
      |> put_resp_content_type(content_type, nil)
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_resp(200, body)
    else
      _ -> pixel(conn)
    end
  end

  def show(conn, _params), do: pixel(conn)

  defp pixel(conn) do
    conn
    |> put_resp_content_type("image/gif")
    |> put_resp_header("cache-control", "private, max-age=60")
    |> send_resp(200, @pixel)
  end
end
