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
     extra_opts: if(mock_run?, do: [websocket_module: Membrane.Gemini.MockWebSocket], else: [])}
  end
end

ExUnit.start(
  capture_log: true,
  exclude: [:integration_only]
)
