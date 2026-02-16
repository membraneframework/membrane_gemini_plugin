defmodule Membrane.Gemini.InputTranscriptEvent do
  @moduledoc """
  Contains input transcripts sent by Gemini.
  """

  @derive Membrane.EventProtocol

  @enforce_keys [:text]

  defstruct @enforce_keys
end
