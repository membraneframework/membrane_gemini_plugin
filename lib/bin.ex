defmodule Membrane.Gemini.Bin do
  @moduledoc """
  A Membrane Bin for integrating with Google's Gemini Live API.

  ## Session lifecycle

  A `Gemini.Live.Session` is started during element initialisation and connected when
  the bin enters the `:playing` state. The session runs for the lifetime of the element.

  If the server sends a `go_away` message, the session is transparently restarted.
  When a [resume handle](https://ai.google.dev/api/live#SessionResumptionConfig.FIELDS.string.SessionResumptionConfig.handle)
  is available the new session picks up the previous conversation context;
  otherwise the session starts fresh.

  The parent can send a `:reset_session` notification to #{inspect(__MODULE__)}
  at any time to force an immediate session restart.

  In addition to audio buffers, the `:output` pad emits events relevant to the streamed response:
  - `Membrane.Gemini.Events.ResponseStart` — signals the beginning of a new model turn.
  - `Membrane.Gemini.Events.ResponseEnd` — signals turn completion or barge-in
    interruption (`interrupted?: true`).
  - `Membrane.Gemini.Events.Thinking` — carries intermediate thinking text when the
    model's thinking mode is enabled.
  - `Membrane.Gemini.Events.Transcript` — carries transcription segments for both
    input audio (`audio_origin: :client`) and the model's audio output (`audio_origin: :server`).

  ## End of stream

  EOS is propagated to the `:output` pad once all input pads have received EOS and
  the model is not currently generating a response. If a response is in progress when
  EOS arrives on both inputs, propagation is deferred until the current turn finishes.
  """

  use Membrane.Bin

  alias Membrane.RawAudio

  def_options mode: [
                spec: :paced | :raw,
                description: """
                Whether the element should output audio as a continuous, real-time stream,
                intertwining the response audio with silence (`:paced`),
                or just the response audio buffers as they come (`:raw`).

                The bin stops on-server response generation upon
                interruption by the user (barge-in).

                When the bin is working in `:raw` mode, received response buffers
                are immediately sent downstream in the pipeline, and so the developer
                has to provide custom mechanisms to detect and get rid of buffers from
                the interrupted response, if they choose to do so,
                e.g. by adding a response UID to the buffer's metadata.

                `:paced` mode discards buffers from the interrupted response automatically,
                and as such is preferred for straightforward LLM integrations.
                """,
                default: :paced
              ],
              model: [
                spec: nil | String.t(),
                description: """
                Name of the model that should be used.
                For details, see `Gemini.Live.Models`.
                """,
                default: nil
              ],
              system_instruction: [
                spec: nil | String.t(),
                description: """
                The [system instruction](https://hexdocs.pm/gemini_ex/system_instructions.html#2-use-structure)
                that will be attached to each prompt for the model to follow.
                """,
                default: nil
              ],
              extra_opts: [
                spec: Keyword.t(),
                description: """
                Extra options that will be passed to `Gemini.Live.Session.start_link/1`.

                NOTE: The bin relies on the following fields to have specific values:
                1. `generation_config.response_modalities == [:audio]`
                2. `realtime_input_config.automatic_activity_detection.disabled == false`
                Changing them may break functionality.

                Examples:

                ## Changing the voice
                ```
                %Membrane.Gemini.Bin{
                  extra_opts: [
                    generation_config: %{
                      # This has to be set
                      response_modalities: [:audio],
                      speech_config: %{
                        voice_config: %{
                          prebuilt_voice_config: %{
                            voice_name: "Sadachbia"
                          }
                        }
                      }
                    }
                  ]
                }
                ```

                ## Enabling context window compression
                ```
                %Membrane.Gemini.Bin{
                  extra_opts: [
                    context_window_compression: %{
                      trigger_tokens: 16_000,
                      sliding_window: %{
                        target_tokens: 8_000
                      }
                    }
                  ]
                }
                ```

                ## Fine-tuning automatic VAD
                ```
                %Membrane.Gemini.Bin{
                  extra_opts: [
                    realtime_input_config: %{
                      automatic_activity_detection: %{
                        start_of_speech_sensitivity: :high,
                        end_of_speech_sensitivity: :low,
                        prefix_padding_ms: 100,
                        silence_duration_ms: 500
                      }
                    }
                  ]
                }
                ```
                """,
                default: []
              ]

  def_input_pad :audio_input,
    accepted_format: %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 16_000}

  def_input_pad :text_input,
    accepted_format: %Membrane.RemoteStream{type: :bytestream}

  def_output_pad :output,
    accepted_format: %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 24_000}

  @impl true
  def handle_init(_ctx, %__MODULE__{
        mode: mode,
        model: model,
        system_instruction: system_instruction,
        extra_opts: extra_opts
      }) do
    spec = [
      bin_input(:audio_input)
      |> via_in(:audio_input)
      |> child(:gemini, %Membrane.Gemini.Endpoint{
        model: model,
        system_instruction: system_instruction,
        extra_opts: extra_opts
      })
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

  defp maybe_realtime_processing(child_spec, :paced),
    do:
      child_spec
      |> child(:queue_filter, Membrane.Gemini.QueueFilter)
      # Options used to enforce synchronous demands from the realtimer to Gemini
      |> via_in(:input, target_queue_size: 1, min_demand_factor: 1)
      |> child(:realtimer, Membrane.Realtimer)

  defp maybe_realtime_processing(child_spec, :raw), do: child_spec
end
