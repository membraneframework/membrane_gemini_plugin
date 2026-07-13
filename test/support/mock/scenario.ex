defmodule GeminiMock.Scenario do
  @moduledoc false
  # Test-facing API of the scripted mock server mode.
  #
  # `setup!/1` registers the calling test process in `GeminiMock.Registry`
  # under a unique token and returns the `extra_opts` to pass to
  # `Membrane.Gemini.Bin`. The token travels as the API key
  # (Bin `extra_opts` → `Gemini.Live.Session` → `Membrane.Gemini.MockWebSocket`
  # → `?key=` query param), so no global application env is touched and each
  # test only ever talks to its own connections.
  #
  # Once a websocket handler upgrades with that token it messages the test:
  #   {:gemini_mock, :connected, conn}      – new connection (conn = handler pid)
  #   {:gemini_mock, :frame, conn, frame}   – decoded JSON frame from the client
  #   {:gemini_mock, :closed, conn, reason} – connection terminated
  # and the test drives it with `push/2` / `close/3`. The `setup` frame is
  # auto-acknowledged with `setupComplete` (the session blocks on it while
  # connecting) unless `auto_setup: false` is given.

  import ExUnit.Assertions

  @default_timeout 5_000

  @spec setup!(Keyword.t()) :: Keyword.t()
  def setup!(opts \\ []) do
    token = "scripted-#{System.unique_integer([:positive])}"
    {:ok, _owner} = Registry.register(GeminiMock.Registry, {:scripted, token}, Map.new(opts))
    [websocket_module: Membrane.Gemini.MockWebSocket, api_key: token]
  end

  @spec await_connection(non_neg_integer()) :: pid()
  def await_connection(timeout \\ @default_timeout) do
    assert_receive {:gemini_mock, :connected, conn}, timeout
    conn
  end

  @spec await_client_frame(pid(), non_neg_integer()) :: map()
  def await_client_frame(conn, timeout \\ @default_timeout) do
    assert_receive {:gemini_mock, :frame, ^conn, frame}, timeout
    frame
  end

  @spec await_close(pid(), non_neg_integer()) :: :ok
  def await_close(conn, timeout \\ @default_timeout) do
    assert_receive {:gemini_mock, :closed, ^conn, _reason}, timeout
    :ok
  end

  @doc "Makes the mock server send the given wire-format frame(s) to the client."
  @spec push(pid(), map() | [map()]) :: :ok
  def push(conn, frames) do
    send(conn, {:gemini_mock, :push, List.wrap(frames)})
    :ok
  end

  @doc "Makes the mock server close the connection with the given code and reason."
  @spec close(pid(), non_neg_integer(), String.t()) :: :ok
  def close(conn, code, reason) do
    send(conn, {:gemini_mock, :close, code, reason})
    :ok
  end
end
