defmodule GeminiMock.Server do
  @moduledoc false
  use Application

  @port 4003

  @impl Application
  def start(_type, _args) do
    children = [
      {Bandit, plug: GeminiMock.Router, scheme: :http, port: @port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
