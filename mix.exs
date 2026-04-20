defmodule Membrane.Gemini.Mixfile do
  use Mix.Project

  @version "0.1.1"
  @github_url "https://github.com/membraneframework/membrane_gemini_plugin"

  def project do
    [
      app: :membrane_gemini_plugin,
      version: @version,
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),

      # hex
      description:
        "Membrane plugin for integrating with Google's Gemini Live API, enabling low-latency bidirectional audio streaming with support for voice activity detection, session management, transcription events, and barge-in interruption handling",
      package: package(),

      # docs
      name: "Membrane Gemini plugin",
      source_url: @github_url,
      docs: docs(),
      homepage_url: "https://membrane.stream"
    ]
  end

  def application do
    [extra_applications: [:logger]] ++
      if(Mix.env() == :test, do: [mod: {GeminiMock.Server, []}], else: [])
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:membrane_core, "~> 1.2.6"},
      {:membrane_raw_audio_format, "~> 0.12.0"},
      {:membrane_realtimer_plugin, "~> 0.10.1"},
      {:gemini_ex, "~> 0.13.0"},
      {:qex, "~> 0.5"},
      {:membrane_file_plugin, "~> 0.17.0", only: :test},
      {:membrane_raw_audio_parser_plugin, "~> 0.4.0", only: :test},
      {:membrane_generator_plugin, "~> 0.10.1", only: :test},
      {:bandit, "~> 1.5", only: :test},
      {:websock_adapter, "~> 0.5", only: :test},
      {:plug, "~> 1.16", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp dialyzer() do
    opts = [
      flags: [:error_handling]
    ]

    if System.get_env("CI") == "true" do
      # Store PLTs in cacheable directory for CI
      [plt_local_path: "priv/plts", plt_core_path: "priv/plts"] ++ opts
    else
      opts
    end
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membrane.stream"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      formatters: ["html"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [Membrane.Gemini]
    ]
  end
end
