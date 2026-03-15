defmodule Membrane.Gemini.Bin do
  @moduledoc """
  A Membrane Bin for integrating with Google's Gemini Live API.

  ## Pads

  - `:audio_input` — mono 16-bit PCM at 16 kHz. Buffers are forwarded to the model
    as realtime audio input. Sending end-of-stream flushes any cached audio on the
    server side.
  - `:text_input` — an arbitrary bytestream. Each buffer's payload is sent verbatim
    as a realtime text input chunk.
  - `:output` — mono 16-bit PCM at 24 kHz, carrying the model's audio responses.
    In addition to audio buffers, the following Membrane events are emitted on this pad:
    - `Membrane.Gemini.Events.ResponseStart` — signals the beginning of a new model turn.
    - `Membrane.Gemini.Events.ResponseEnd` — signals turn completion or barge-in
      interruption (`interrupted?: true`).
    - `Membrane.Gemini.Events.Thinking` — carries intermediate thinking text when the
      model's thinking mode is enabled.
    - `Membrane.Gemini.Events.Transcript` — carries transcription segments for both
      input audio (`direction: :input`) and the model's audio output (`direction: :output`).

  ## Session lifecycle

  A `Gemini.Live.Session` is started during element initialisation and connected when
  the bin enters the `:playing` state. The session runs for the lifetime of the element.

  If the server sends a `go_away` message, the session is transparently restarted. When
  a resume handle is available the new session picks up the previous conversation context;
  otherwise the session starts fresh.

  A `:reset_session` parent notification can also be sent at any time to force an
  immediate session restart (without a resume handle).

  ## End of stream

  EOS is propagated to the `:output` pad once both input pads have received EOS and
  the model is not currently generating a response. If a response is in progress when
  EOS arrives on both inputs, propagation is deferred until the current turn finishes.
  """

  use Membrane.Bin

  alias Membrane.RawAudio

  def_options mode: [
                spec: :continuous | :discrete,
                description:
                  """
                  Whether the element should output audio as a continuous stream,
                  intertwining the response audio with silence, or just the response audio buffers.
                  The first option is ideal for straightforward LLM integrations
                  that don't require additional audio processing.
                  The second is better if one wants more fine-grained control without needing VAD mechanisms.
                  """,
                default: :continuous
              ],
              config: [
                spec: Membrane.Gemini.Config.t(),
                description:
                  """
                  Used to configure the `gemini_ex` GenServer managing the Live API session.
                  For more details, see `Membrane.Gemini.Config`.
                  """,
                default: %Membrane.Gemini.Config{}
              ]

  def_input_pad :audio_input,
    accepted_format: %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 16_000}

  def_input_pad :text_input,
    accepted_format: %Membrane.RemoteStream{type: :bytestream}

  def_output_pad :output,
    accepted_format: %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 24_000}

  @impl true
  def handle_init(_ctx, %{mode: mode, config: config} = _opts) do

    spec = [
      bin_input(:audio_input)
      |> via_in(:audio_input)
      |> child(:gemini, %Membrane.Gemini.Endpoint{config: config})
      |> maybe_realtime_processing(mode)
      |> bin_output(:output),
      bin_input(:text_input)
      |> via_in(:text_input)
      |> get_child(:gemini)
    ]

    {[spec: spec], %{}}
  end

  @impl true
  def handle_parent_notification(:reset_session, _ctx, state),
    do: {[notify_child: {:gemini, :reset_session}], state}

  defp maybe_realtime_processing(child_spec, :continuous), do:
          child_spec
          |> child(:queue, Membrane.Gemini.QueueFilter)
          # Options used to enforce synchronous demands from the realtimer to Gemini
          |> via_in(:input, target_queue_size: 1, min_demand_factor: 1)
          |> child(:realtimer, Membrane.Realtimer)
  defp maybe_realtime_processing(child_spec, :discrete), do: child_spec
end
