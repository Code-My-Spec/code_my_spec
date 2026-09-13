defmodule CodeMySpecWeb.TheSocketTokenIsNotInTheLogTest do
  @moduledoc """
  A deploy key must not reach `web.log`.

  Issue `d96809d4`. `UserSocket` authenticates with a token in the socket's
  connect *parameters*, and Phoenix logs those parameters verbatim on every
  connection. So each successful join wrote a live 128-character deploy key
  into the log in the clear — the same key that is in the environment on this
  machine — two lines away from a refusal line that goes to the trouble of
  logging only a SHA-256 prefix precisely so a pasted log is not replayable.

  The trap is the default. `Phoenix.Logger.filter_values/2` falls back to `[]`
  when nothing is configured, not to the `["password"]` its own docs quote —
  that list is written into `config.exs` by the app generator, and this
  application never had it. So the filter existed, ran on every request, and
  filtered nothing.

  Asserted through `filter_values/2` rather than by capturing a log line: the
  logger is Phoenix's and is not the thing that can regress here. What can
  regress is the configuration, which is one line in `config/config.exs` and
  has no other reader.
  """

  use ExUnit.Case, async: true

  @deploy_key String.duplicate("a1b2c3d4", 16)

  test "the token a socket connects with is filtered" do
    params = %{"token" => @deploy_key, "vsn" => "2.0.0"}

    assert %{"token" => "[FILTERED]", "vsn" => "2.0.0"} = Phoenix.Logger.filter_values(params),
           """
           The socket's connect parameters are logged verbatim on every connection,
           so an unfiltered token is a live credential in web.log.
           """
  end

  test "and so is anything else named like a credential" do
    values = %{
      "deploy_key" => @deploy_key,
      "api_key" => "sk-live",
      "password" => "hunter2",
      "client_secret" => "shh"
    }

    for {name, filtered} <- Phoenix.Logger.filter_values(values) do
      assert filtered == "[FILTERED]",
             "#{name} is logged in the clear; the filter matches on substrings of the " <>
               "parameter name, so a credential named outside those terms needs a new one"
    end
  end

  test "and ordinary parameters still say what they were" do
    values = %{"vsn" => "2.0.0", "email" => "someone@example.com", "project_id" => "42"}

    assert Phoenix.Logger.filter_values(values) == values,
           """
           Everything is filtered, which makes the log useless for diagnosis —
           that is the failure mode of reaching for {:keep, [...]} instead.
           """
  end
end
