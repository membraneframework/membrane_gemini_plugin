defmodule Membrane.Gemini.ResponseEndEvent do
  @moduledoc """
  Sent by `Membrane.Gemini.Endpoint` upon model turn completion or interruption.
  """

  @derive Membrane.EventProtocol

  @enforce_keys [:interrupted]

  defstruct @enforce_keys
end
