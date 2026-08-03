defmodule CodeMySpec.Provisioning.Wait do
  @moduledoc """
  The pause between polls, in one place so it can be switched off.

  Provisioning is full of "ask again in a moment" loops: a server is not
  running the instant Hetzner accepts the create, a bucket is not gone the
  instant Ceph accepts the delete, a DNS record does not resolve the instant
  Cloudflare stores it. Against a real provider those waits are the whole
  point.

  Against a **replayed cassette** they are pure cost. The answer is already
  recorded, so a poll that took three attempts to succeed replays as three
  instant reads with two real sleeps wedged between them — the waiting is
  faithfully reproduced and there is nothing left to wait for. That is why a
  single passing criterion took five and a half minutes.

  So the interval is a function of the mode rather than a constant. Nothing
  else changes: the same number of polls happen in the same order, and a
  cassette recorded through this module replays through it identically.
  """

  @doc """
  Sleep, unless the caller is replaying a cassette.

  Configured rather than passed, because the pollers that need it are several
  layers below whoever knows which mode the run is in, and threading an option
  through each of them would put the knowledge in the wrong places.
  """
  @spec sleep(non_neg_integer()) :: :ok
  def sleep(milliseconds) when is_integer(milliseconds) and milliseconds >= 0 do
    case Application.get_env(:code_my_spec, :provisioning_waits, :real) do
      :none -> :ok
      _ -> Process.sleep(milliseconds)
    end
  end
end
