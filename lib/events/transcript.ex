defmodule Membrane.Gemini.Events.Transcript do
  @moduledoc """
  Contains transcripts for audio data,
  either client input (`direction: :input`),
  or model response (`direction: :output`).
  """

  @derive Membrane.EventProtocol

  @type t :: %__MODULE__{
          text: String.t(),
          direction: :input | :output
        }

  @enforce_keys [:text, :direction]

  defstruct @enforce_keys
end
