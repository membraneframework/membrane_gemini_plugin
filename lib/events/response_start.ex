defmodule Membrane.Gemini.Events.ResponseStart do
  @moduledoc """
  Sent by `Membrane.Gemini.Bin` when it starts receiving a new response.
  """

  @derive Membrane.EventProtocol

  defstruct []
end
