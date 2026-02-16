# Membrane Gemini Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_gemini_plugin.svg)](https://hex.pm/packages/membrane_gemini_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_gemini_plugin)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_gemini_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_gemini_plugin)

A Membrane plugin for easy integration with the Gemini Live API, establishing a WebSocket connection for low-latency audio streaming.

It's a part of the [Membrane Framework](https://membrane.stream).

## Installation

The package can be installed by adding `membrane_gemini_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_gemini_plugin, "~> 0.1.0"}
  ]
end
```

## Examples

See `examples/talking_demo.exs` for a simple demo that allows conversation with Gemini and additional text prompting.

## Copyright and License

Copyright 2020, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_gemini_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_gemini_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
