defmodule Membrane.Gemini.OutputTranscriptEvent do
  @moduledoc """
  Contains output transcripts sent by Gemini.
  """

  @derive Membrane.EventProtocol

  @enforce_keys [:text]

  defstruct @enforce_keys
end
