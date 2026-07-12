#!/usr/bin/env sh
# shellcheck shell="busybox ash"
# Alpine Linux uses BusyBox ash as the default shell.
# https://wiki.alpinelinux.org/wiki/Shell_management
set -eu -o pipefail

ANALYZE_AUDIO=/usr/local/lib/sox/analyze_audio.sh

USAGE="
Usage:
  entrypoint.sh [options] INPUT

Options:
  -o, --output-dir DIR              Write reports and outputs to DIR.
                                    Default: input file directory.
      --mkv-tracks TRACKS           Comma-separated MKV track IDs from mkvmerge -J.
                                    Default: all lossless mono or stereo audio tracks.
      --mkv-output FILE             Write the remuxed MKV to FILE instead of
                                    overwriting the input MKV.
      --spectrogram-trim SEC        Generate spectrograms for SEC seconds.
                                    Detection still scans the full input.
      --spectrogram-start POS       Start spectrograms at POS. Default: 0.
      --spectrogram-width PX        Spectrogram plot width. Default: 3000.
      --spectrogram-height PX       Spectrogram height per channel. Default: 513.
      --no-waveforms                Skip waveform PNG generation.
      --no-spectrograms             Skip PNG spectrogram generation.
      --no-mono                     Do not write a mono FLAC even if dual mono.
      --strict-dual-mono            Require exact side digital silence for dual mono.
      --dual-mono-peak-threshold DB Effective dual mono side peak threshold.
																		Default: -86.02.
      --dual-mono-rms-threshold DB  Effective dual mono side RMS threshold.
                                    Default: -126.02.
      --write-flac            			Write INPUT_BASENAME.audio.flac. Default: enabled.
      --no-write-flac         			Do not write INPUT_BASENAME.audio.flac.
      --strip-padding         			Strip FLAC padding when safe. Default: enabled.
      --no-strip-padding      			Preserve decoded source precision.
      --padding-target-bits N 			Bit depth used by padding stripping.
                              			Use auto, 8, 16, or 24. Default: auto.
  -h, --help                  			Show this help.

Direct audio inputs run SoX analysis. MKV inputs decode selected lossless mono
or stereo audio tracks, analyze them, remux replacement FLAC tracks, and
overwrite the input MKV after a successful remux unless --mkv-output is used.
"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

require_value() {
	local option="$1"
	local value="${2-}"

	[ -n "$value" ] || die "$option requires a value"
}

require_commands() {
	local command

	for command in "$@"; do
		if ! command -v "$command" >/dev/null 2>&1; then
			die "$command could not be found"
		fi
	done
}

validate_track_csv() {
	local value="$1"

	case "$value" in
	"" | *[!0-9,]* | ,* | *, | *,,*)
		die "--mkv-tracks must be a comma-separated list of nonnegative integers"
		;;
	esac
}

csv_contains() {
	local csv="$1"
	local value="$2"

	case ",$csv," in
	*",$value,"*) return 0 ;;
	*) return 1 ;;
	esac
}

append_csv() {
	local csv="$1"
	local value="$2"

	if [ -n "$csv" ]; then
		printf '%s,%s' "$csv" "$value"
	else
		printf '%s' "$value"
	fi
}

bool_to_mkvmerge() {
	case "$1" in
	true | 1 | yes)
		printf 'yes'
		;;
	*)
		printf 'no'
		;;
	esac
}

print_and_run() {
	local argument

	printf '\n------------------\n' >&2
	for argument in "$@"; do
		printf ' %s' "$argument" >&2
	done
	printf '\n------------------\n' >&2
	"$@"
}

resolve_input_file() {
	local input="$1"
	local input_dir
	local input_name

	input_dir="$(cd "$(dirname "$input")" && pwd -P)" || die "input directory not found: $(dirname "$input")"
	input_name="$(basename "$input")"
	[ -f "$input_dir/$input_name" ] || die "input file not found: $input"
	printf '%s/%s' "$input_dir" "$input_name"
}

resolve_output_dir() {
	local output_dir="$1"

	mkdir -p "$output_dir"
	cd "$output_dir" && pwd -P
}

resolve_output_file() {
	local output_file="$1"
	local output_dir
	local output_name

	output_dir="$(dirname "$output_file")"
	output_name="$(basename "$output_file")"
	mkdir -p "$output_dir"
	output_dir="$(cd "$output_dir" && pwd -P)" || die "output directory not found: $(dirname "$output_file")"
	printf '%s/%s' "$output_dir" "$output_name"
}

get_report_field() {
	local key="$1"
	local report="$2"

	awk -F': ' -v key="$key" '$1 == key { print substr($0, length(key) + 3); found = 1; exit } END { if (!found) exit 1 }' "$report" 2>/dev/null || true
}

run_audio_analysis() {
	local analysis_input="$1"
	local analysis_output_dir="$2"
	local analysis_base="$3"

	print_and_run "$ANALYZE_AUDIO" "$analysis_input" "$analysis_output_dir" "$analysis_base"
}

write_mkv_summary() {
	local summary_path="$1"
	local input_path="$2"
	local target_path="$3"
	local output_mode="$4"
	local replacement_track_ids_file="$5"
	local preserved_track_summaries_file="$6"
	local tmp_dir="$7"
	local replacement_path
	local track_id

	{
		printf 'SoX MKV analysis report\n'
		printf '\n'
		printf 'Input: %s\n' "$input_path"
		printf 'Output: %s\n' "$target_path"
		printf 'Output mode: %s\n' "$output_mode"
		printf 'Track selection: %s\n' "${MKV_TRACKS:-all lossless mono or stereo audio tracks}"
		printf '\n'
		printf 'Replaced tracks:\n'
		if [ ! -s "$replacement_track_ids_file" ]; then
			printf '%s\n' '- none'
		else
			while IFS= read -r track_id; do
				replacement_path="$(cat "$tmp_dir/replacement.$track_id.path")"
				printf '%s\n' "- Track $track_id: $replacement_path"
			done <"$replacement_track_ids_file"
		fi
		printf '\n'
		printf 'Preserved or skipped audio tracks:\n'
		if [ ! -s "$preserved_track_summaries_file" ]; then
			printf '%s\n' '- none'
		else
			cat "$preserved_track_summaries_file"
		fi
	} >"$summary_path"
}

process_mkv() {
	local input_path="$1"
	local input_base="$2"
	local output_dir="$3"
	local metadata_file
	local mediainfo_file
	local track_json_file
	local requested_track_ids_file
	local replacement_track_ids_file
	local preserved_track_summaries_file
	local track_json
	local track_id
	local track_type
	local track_channels
	local track_codec
	local track_compression_mode
	local requested_id
	local requested_track_type
	local audio_index=0
	local replacement_input_index=1
	local replacement_count=0
	local selected_for_analysis
	local tmp_dir
	local target_path
	local target_mode
	local remux_tmp
	local summary_path
	local audio_tracks_spec
	local track_order
	local ffmpeg_map
	local track_base
	local decoded_flac
	local report_path
	local mono_path
	local flac_path
	local replacement_path
	local dual_mono
	local default_flag
	local forced_flag
	local language
	local track_name
	local replacement_track_ids
	local replacement_input
	local track_order_item

	require_commands ffmpeg jq mediainfo mkvmerge

	[ "$WRITE_FLAC" = "1" ] || die "MKV mode requires --write-flac so replacement FLAC tracks can be remuxed"

	tmp_dir="$(mktemp -d)"
	remux_tmp=""
	cleanup_mkv() {
		if [ -n "$remux_tmp" ] && [ -f "$remux_tmp" ]; then
			rm -f "$remux_tmp"
		fi
		rm -rf "$tmp_dir"
	}
	trap cleanup_mkv 0 HUP INT TERM

	metadata_file="$tmp_dir/$input_base.mkvmerge.json"
	mediainfo_file="$tmp_dir/$input_base.mediainfo.json"
	track_json_file="$tmp_dir/tracks.jsonl"
	requested_track_ids_file="$tmp_dir/requested-track-ids.txt"
	replacement_track_ids_file="$tmp_dir/replacement-track-ids.txt"
	preserved_track_summaries_file="$tmp_dir/preserved-track-summaries.txt"
	: >"$replacement_track_ids_file"
	: >"$preserved_track_summaries_file"
	print_and_run mkvmerge -J "$input_path" >"$metadata_file"
	print_and_run mediainfo --Output=JSON "$input_path" >"$mediainfo_file"
	jq -c '.tracks[]' "$metadata_file" >"$track_json_file"

	if [ -n "$MKV_TRACKS" ]; then
		printf '%s\n' "$MKV_TRACKS" | tr ',' '\n' >"$requested_track_ids_file"
		while IFS= read -r requested_id; do
			requested_track_type="$(
				jq -r --argjson id "$requested_id" \
					'first(.tracks[] | select(.id == $id) | .type) // empty' \
					"$metadata_file"
			)"
			[ -n "$requested_track_type" ] || die "MKV track ID $requested_id was not found"
			[ "$requested_track_type" = "audio" ] || die "MKV track ID $requested_id is not an audio track"
		done <"$requested_track_ids_file"
	fi

	while IFS= read -r track_json; do
		track_id="$(printf '%s\n' "$track_json" | jq -r '.id')"
		track_type="$(printf '%s\n' "$track_json" | jq -r '.type')"
		track_channels="$(printf '%s\n' "$track_json" | jq -r '.properties.audio_channels // empty')"
		track_codec="$(printf '%s\n' "$track_json" | jq -r '.codec // "unknown"')"
		selected_for_analysis=0

		if [ "$track_type" != "audio" ]; then
			continue
		fi

		ffmpeg_map="0:a:$audio_index"
		track_compression_mode="$(
			jq -r --argjson index "$audio_index" \
				'[.media.track[] | select(."@type" == "Audio")][$index].Compression_Mode // empty' \
				"$mediainfo_file"
		)"
		audio_index=$((audio_index + 1))

		if [ -n "$MKV_TRACKS" ]; then
			if csv_contains "$MKV_TRACKS" "$track_id"; then
				selected_for_analysis=1
			fi
		elif { [ "$track_channels" = "1" ] || [ "$track_channels" = "2" ]; } && [ "$track_compression_mode" = "Lossless" ]; then
			selected_for_analysis=1
		fi

		if [ "$selected_for_analysis" = "0" ]; then
			if [ -z "$MKV_TRACKS" ] && { [ "$track_channels" = "1" ] || [ "$track_channels" = "2" ]; }; then
				printf '%s\n' "- Track $track_id preserved: ${track_compression_mode:-unknown} compression mode is not lossless" >>"$preserved_track_summaries_file"
			else
				printf '%s\n' "- Track $track_id preserved: not selected" >>"$preserved_track_summaries_file"
			fi
			continue
		fi

		if [ "$track_channels" != "1" ] && [ "$track_channels" != "2" ]; then
			printf '%s\n' "- Track $track_id preserved: $track_channels channels are not mono or stereo" >>"$preserved_track_summaries_file"
			continue
		fi

		track_base="$input_base.audio.track-$track_id"
		decoded_flac="$tmp_dir/$track_base.decoded.flac"

		print_and_run ffmpeg -nostdin -hide_banner -loglevel error -y \
			-i "$input_path" \
			-map "$ffmpeg_map" \
			-vn \
			-sn \
			-dn \
			-c:a flac \
			-compression_level 8 \
			"$decoded_flac"

		run_audio_analysis "$decoded_flac" "$output_dir" "$track_base"

		report_path="$output_dir/$track_base.report.txt"
		mono_path="$output_dir/$track_base.mono.flac"
		flac_path="$output_dir/$track_base.flac"
		dual_mono="$(get_report_field "Dual mono" "$report_path")"

		if [ "$NO_MONO" = "0" ] && [ "$dual_mono" = "yes" ] && [ -f "$mono_path" ]; then
			replacement_path="$mono_path"
		else
			replacement_path="$flac_path"
		fi

		[ -f "$replacement_path" ] || die "analysis did not produce a replacement FLAC for MKV track $track_id"

		printf '%s\n' "$track_id" >>"$replacement_track_ids_file"
		printf '%s' "$replacement_path" >"$tmp_dir/replacement.$track_id.path"
		printf '%s' "$replacement_input_index" >"$tmp_dir/replacement.$track_id.input"
		replacement_input_index=$((replacement_input_index + 1))
		replacement_count=$((replacement_count + 1))
		printf 'Track %s replacement: %s (%s, %s channels)\n' "$track_id" "$replacement_path" "$track_codec" "$track_channels"
	done <"$track_json_file"

	[ "$replacement_count" -gt 0 ] || die "no MKV audio tracks were eligible for replacement"

	if [ -n "$MKV_OUTPUT" ]; then
		target_path="$(resolve_output_file "$MKV_OUTPUT")"
		target_mode="explicit output"
	else
		target_path="$input_path"
		target_mode="overwrite input"
	fi

	remux_tmp="$target_path.tmp.$$"
	replacement_track_ids=""
	while IFS= read -r track_id; do
		replacement_track_ids="$(append_csv "$replacement_track_ids" "$track_id")"
	done <"$replacement_track_ids_file"
	audio_tracks_spec="!$replacement_track_ids"
	set -- mkvmerge -o "$remux_tmp" --audio-tracks "$audio_tracks_spec" "$input_path"

	while IFS= read -r track_id; do
		track_json="$(jq -c --argjson id "$track_id" '.tracks[] | select(.id == $id)' "$metadata_file")"
		language="$(printf '%s\n' "$track_json" | jq -r '.properties.language // "und"')"
		track_name="$(printf '%s\n' "$track_json" | jq -r '.properties.track_name // ""')"
		default_flag="$(bool_to_mkvmerge "$(printf '%s\n' "$track_json" | jq -r '.properties.default_track // false')")"
		forced_flag="$(bool_to_mkvmerge "$(printf '%s\n' "$track_json" | jq -r '.properties.forced_track // false')")"
		replacement_path="$(cat "$tmp_dir/replacement.$track_id.path")"

		set -- "$@" --language "0:$language"
		if [ -n "$track_name" ]; then
			set -- "$@" --track-name "0:$track_name"
		fi
		set -- "$@" \
			--default-track-flag "0:$default_flag"
		set -- "$@" \
			--forced-display-flag "0:$forced_flag" \
			"$replacement_path"
	done <"$replacement_track_ids_file"

	track_order=""
	while IFS= read -r track_json; do
		track_id="$(printf '%s\n' "$track_json" | jq -r '.id')"
		if [ -f "$tmp_dir/replacement.$track_id.input" ]; then
			replacement_input="$(cat "$tmp_dir/replacement.$track_id.input")"
			track_order_item="$replacement_input:0"
		else
			track_order_item="0:$track_id"
		fi
		track_order="$(append_csv "$track_order" "$track_order_item")"
	done <"$track_json_file"

	set -- "$@" --track-order "$track_order"

	print_and_run "$@"
	mv "$remux_tmp" "$target_path"
	remux_tmp=""

	summary_path="$output_dir/$input_base.audio.mkv.report.txt"
	write_mkv_summary \
		"$summary_path" \
		"$input_path" \
		"$target_path" \
		"$target_mode" \
		"$replacement_track_ids_file" \
		"$preserved_track_summaries_file" \
		"$tmp_dir"
	printf 'MKV report: %s\n' "$summary_path"
	printf 'MKV output: %s\n' "$target_path"
	trap - 0 HUP INT TERM
	rm -rf "$tmp_dir"
}

OUTPUT_DIR=""
SPECTROGRAM_TRIM=""
SPECTROGRAM_START="0"
SPECTROGRAM_WIDTH="3000"
SPECTROGRAM_CHANNEL_HEIGHT="513"
NO_SPECTROGRAMS=0
NO_WAVEFORMS=0
NO_MONO=0
STRICT_DUAL_MONO=0
DUAL_MONO_PEAK_THRESHOLD="-86.02"
DUAL_MONO_RMS_THRESHOLD="-126.02"
WRITE_FLAC=1
STRIP_PADDING=1
PADDING_TARGET_BITS=auto
MKV_TRACKS=""
MKV_OUTPUT=""
INPUT=""

while [ "$#" -gt 0 ]; do
	case "$1" in
	-o | --output-dir)
		require_value "$1" "${2-}"
		OUTPUT_DIR="$2"
		shift 2
		;;
	--mkv-tracks)
		require_value "$1" "${2-}"
		validate_track_csv "$2"
		MKV_TRACKS="$2"
		shift 2
		;;
	--mkv-output)
		require_value "$1" "${2-}"
		MKV_OUTPUT="$2"
		shift 2
		;;
	--spectrogram-trim)
		require_value "$1" "${2-}"
		SPECTROGRAM_TRIM="$2"
		shift 2
		;;
	--spectrogram-start)
		require_value "$1" "${2-}"
		SPECTROGRAM_START="$2"
		shift 2
		;;
	--spectrogram-width)
		require_value "$1" "${2-}"
		SPECTROGRAM_WIDTH="$2"
		shift 2
		;;
	--spectrogram-height)
		require_value "$1" "${2-}"
		SPECTROGRAM_CHANNEL_HEIGHT="$2"
		shift 2
		;;
	--no-spectrograms)
		NO_SPECTROGRAMS=1
		shift
		;;
	--no-waveforms)
		NO_WAVEFORMS=1
		shift
		;;
	--no-mono)
		NO_MONO=1
		shift
		;;
	--strict-dual-mono)
		STRICT_DUAL_MONO=1
		shift
		;;
	--dual-mono-peak-threshold)
		require_value "$1" "${2-}"
		DUAL_MONO_PEAK_THRESHOLD="$2"
		shift 2
		;;
	--dual-mono-rms-threshold)
		require_value "$1" "${2-}"
		DUAL_MONO_RMS_THRESHOLD="$2"
		shift 2
		;;
	--write-flac)
		WRITE_FLAC=1
		shift
		;;
	--no-write-flac)
		WRITE_FLAC=0
		shift
		;;
	--strip-padding)
		STRIP_PADDING=1
		shift
		;;
	--no-strip-padding)
		STRIP_PADDING=0
		shift
		;;
	--padding-target-bits)
		require_value "$1" "${2-}"
		PADDING_TARGET_BITS="$2"
		shift 2
		;;
	-h | --help)
		printf '%s' "$USAGE"
		exit 0
		;;
	-*)
		printf '%s' "$USAGE" >&2
		die "unknown option: $1"
		;;
	*)
		if [ -n "$INPUT" ]; then
			printf '%s' "$USAGE" >&2
			die "only one input file is supported"
		fi
		INPUT="$1"
		shift
		;;
	esac
done

[ -n "$INPUT" ] || {
	printf '%s' "$USAGE" >&2
	die "missing input file"
}

case "$PADDING_TARGET_BITS" in
auto | 8 | 16 | 24)
	;;
*)
	die "--padding-target-bits must be auto, 8, 16, or 24 for SoX FLAC output"
	;;
esac
[ -x "$ANALYZE_AUDIO" ] || die "analysis helper not found or not executable: $ANALYZE_AUDIO"

export NO_SPECTROGRAMS
export NO_WAVEFORMS
export NO_MONO
export STRICT_DUAL_MONO
export DUAL_MONO_PEAK_THRESHOLD
export DUAL_MONO_RMS_THRESHOLD
export WRITE_FLAC
export STRIP_PADDING
export PADDING_TARGET_BITS
export SPECTROGRAM_TRIM
export SPECTROGRAM_START
export SPECTROGRAM_WIDTH
export SPECTROGRAM_CHANNEL_HEIGHT

input_path="$(resolve_input_file "$INPUT")"
input_name="$(basename "$input_path")"
input_base="${input_name%.*}"
if [ "$input_base" = "$input_name" ]; then
	input_base="$input_name"
fi

if [ -z "$OUTPUT_DIR" ]; then
	OUTPUT_DIR="$(dirname "$input_path")"
fi
output_dir="$(resolve_output_dir "$OUTPUT_DIR")"

printf 'Input: %s\n' "$input_path"
printf 'Output directory: %s\n' "$output_dir"

lower_input="$(printf '%s' "$input_name" | tr '[:upper:]' '[:lower:]')"
case "$lower_input" in
*.mkv)
	process_mkv "$input_path" "$input_base" "$output_dir"
	;;
*)
	if [ -n "$MKV_TRACKS" ] || [ -n "$MKV_OUTPUT" ]; then
		die "--mkv-tracks and --mkv-output can only be used with MKV inputs"
	fi
	require_commands ffmpeg sox soxi uv
	analysis_base="$input_base.audio"
	run_audio_analysis "$input_path" "$output_dir" "$analysis_base"
	report_path="$output_dir/$analysis_base.report.txt"
	[ -f "$report_path" ] || die "analysis finished but did not write report: $report_path"
	printf 'Done. See %s\n' "$report_path"
	;;
esac
