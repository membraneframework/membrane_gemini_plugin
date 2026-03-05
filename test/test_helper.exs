defmodule Membrane.Gemini.Case do
  use ExUnit.CaseTemplate

  using do
    quote do
      # Tests need to be run synchronously unless `gemini_ex`
      # starts supporting configuring the API key in a way other than
      # through an env-var.
      use ExUnit.Case, async: false
    end
  end

  setup do
    mock_run? = System.get_env("GEMINI_API_KEY") == "mock-api-key"

    {:ok,
     mock_run?: mock_run?,
     gemini_config: %Membrane.Gemini.Config{
       extra_opts: if(mock_run?, do: [websocket_module: Membrane.Gemini.MockWebSocket], else: [])
     }}
  end
end

System.put_env("GEMINI_API_KEY", System.get_env("GEMINI_API_KEY") || "mock-api-key")
mock_run? = System.get_env("GEMINI_API_KEY") == "mock-api-key"

if mock_run? do
  children = [
    {Bandit, plug: GeminiMock.Router, port: 4003, startup_log: false}
  ]

  {:ok, _pid} =
    Supervisor.start_link(children, strategy: :one_for_one, name: GeminiMock.Supervisor)

  ExUnit.start(
    capture_log: true,
    exclude: [:integration_only]
  )
else
  ExUnit.start(
    capture_log: true,
    exclude: [:mock_only]
  )
end
