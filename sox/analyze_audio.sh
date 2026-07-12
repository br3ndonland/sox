#!/usr/bin/env sh
# shellcheck shell="busybox ash"
# Alpine Linux uses BusyBox ash as the default shell.
# https://wiki.alpinelinux.org/wiki/Shell_management
set -eu

input="$1"
output_dir="$2"
base="$3"

for command in ffmpeg sox soxi uv; do
	if ! command -v "$command" >/dev/null 2>&1; then
		printf 'error: %s could not be found\n' "$command" >&2
		exit 1
	fi
done

need_ffmpeg=0
lower_input="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
case "$lower_input" in
*.ac3 | *.eac3 | *.dts | *.dtshd | *.dtsma)
	need_ffmpeg=1
	;;
esac

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
work_input="$input"
decode_note="not needed"

if [ "$need_ffmpeg" -eq 1 ]; then
	work_input="$tmp_dir/$base.decoded.flac"
	ffmpeg -nostdin -hide_banner -loglevel error -y \
		-i "$input" \
		-map 0:a:0 \
		-c:a flac \
		-compression_level 8 \
		"$work_input"
	decode_note="decoded to temporary FLAC with ffmpeg FLAC compression level 8"
fi

source_info="$output_dir/$base.source.txt"
source_stats="$output_dir/$base.stats.source.txt"
side_stats="$output_dir/$base.stats.side-l-minus-r.txt"
mid_stats="$output_dir/$base.stats.mid-l-plus-r.txt"
report="$output_dir/$base.report.txt"
mono_output="$output_dir/$base.mono.flac"
flac_output="$output_dir/$base.flac"
spectrogram_output="$output_dir/$base.spectrograms.png"
waveform_output="$output_dir/$base.waveforms.png"
matrix_mid_spectrogram="$output_dir/$base.mid-l-plus-r.png"
matrix_side_spectrogram="$output_dir/$base.side-l-minus-r.png"
matrix_mid_side_waveform="$output_dir/$base.mid-side-waveforms.png"
mid_remix_spec="1v0.5,2v0.5"
side_remix_spec="1v0.5,2v-0.5"

soxi "$work_input" >"$source_info" 2>&1
sox "$work_input" -n stats >"$source_stats" 2>&1

channels="$(soxi -c "$work_input")"
sample_rate="$(soxi -r "$work_input")"
precision_bits="$(soxi -b "$work_input")"
duration_seconds="$(soxi -D "$work_input")"

strict_dual_mono="no"
effective_dual_mono="no"
dual_mono="no"
dual_mono_reason="not evaluated"
dual_mono_mode="effective"
dual_mono_peak_threshold="${DUAL_MONO_PEAK_THRESHOLD:--86.02}"
dual_mono_rms_threshold="${DUAL_MONO_RMS_THRESHOLD:--126.02}"
opposite_phase_duplicate="no"
side_pk="skipped"
side_rms="skipped"
mid_pk="skipped"
mid_rms="skipped"
mono_status="skipped"
mono_output_bits="unknown"
flac_output_status="skipped"
flac_output_bits="unknown"
flac_output_reason="not evaluated"
write_flac_enabled="yes"
spectrogram_status="skipped"
waveform_status="skipped"
matrix_status="skipped"
matrix_side_mid_delta_db="skipped"
matrix_correlation="skipped"
matrix_heuristic="skipped"
padding_supported_flac_bits="8 16 24"
padding_target_setting="${PADDING_TARGET_BITS:-auto}"
padding_target_bits="unknown"
padding_bit_depth_line="unknown"
padding_max_reported_bits="unknown"
padding_safe="no"
padding_reason="not evaluated"
padding_status="not evaluated"
padding_strip_enabled="yes"

get_pk_db() {
	awk '$1 == "Pk" && $2 == "lev" && $3 == "dB" { print $4; found=1; exit } END { if (!found) exit 1 }' "$1" 2>/dev/null || printf 'unknown'
}

get_rms_db() {
	awk '$1 == "RMS" && $2 == "lev" && $3 == "dB" { print $4; found=1; exit } END { if (!found) exit 1 }' "$1" 2>/dev/null || printf 'unknown'
}

get_bit_depth_line() {
	awk '
    $1 == "Bit-depth" {
      for (i = 2; i <= NF; i++) {
        if (i > 2) printf " ";
        printf "%s", $i;
      }
      printf "\n";
      found = 1;
      exit;
    }
    END { if (!found) exit 1 }
  ' "$1" 2>/dev/null || printf 'unknown'
}

get_max_bit_depth_bits() {
	awk '
    $1 == "Bit-depth" {
      found_line = 1;
      max_bits = 0;
      found_bits = 0;
      for (i = 2; i <= NF; i++) {
        split($i, parts, "/");
        for (j in parts) {
          if (parts[j] ~ /^[0-9]+$/) {
            found_bits = 1;
            if (parts[j] + 0 > max_bits) max_bits = parts[j] + 0;
          }
        }
      }
      if (found_bits) {
        print max_bits;
        exit 0;
      }
      exit 1;
    }
    END { if (!found_line) exit 1 }
  ' "$1" 2>/dev/null || printf 'unknown'
}

is_positive_integer() {
	case "$1" in
	"" | *[!0-9]*)
		return 1
		;;
	esac
	[ "$1" -gt 0 ]
}

is_nonnegative_integer() {
	case "$1" in
	"" | *[!0-9]*)
		return 1
		;;
	esac
	return 0
}

resolve_supported_flac_bits() {
	requested_bits="$1"

	if ! is_nonnegative_integer "$requested_bits"; then
		return 1
	fi

	for supported_bits in $padding_supported_flac_bits; do
		if [ "$requested_bits" -le "$supported_bits" ]; then
			printf '%s\n' "$supported_bits"
			return 0
		fi
	done

	return 1
}

is_supported_flac_bits() {
	case "$1" in
	8 | 16 | 24)
		return 0
		;;
	esac
	return 1
}

is_finite_db() {
	case "$1" in
	"" | unknown | skipped | n/a | inf | -inf)
		return 1
		;;
	esac
	return 0
}

is_db_number() {
	awk -v value="$1" 'BEGIN { exit(value ~ /^-?[0-9]+([.][0-9]+)?$/ ? 0 : 1) }'
}

db_at_or_below() {
	value="$1"
	threshold="$2"

	case "$value" in
	-inf)
		return 0
		;;
	"" | unknown | skipped | n/a | inf)
		return 1
		;;
	esac

	if ! is_db_number "$value" || ! is_db_number "$threshold"; then
		return 1
	fi

	awk -v value="$value" -v threshold="$threshold" 'BEGIN { exit(value <= threshold ? 0 : 1) }'
}

calc_db_delta() {
	if is_finite_db "$1" && is_finite_db "$2"; then
		awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", a - b }'
	else
		printf 'n/a'
	fi
}

calc_correlation_from_delta() {
	if is_finite_db "$1"; then
		awk -v d="$1" 'BEGIN { r = 10 ^ (d / 10); c = (1 - r) / (1 + r); printf "%.3f", c }'
	else
		printf 'n/a'
	fi
}

classify_matrix_delta() {
	if ! is_finite_db "$1"; then
		printf 'skipped'
		return
	fi

	awk -v d="$1" 'BEGIN {
    if (d <= -20) {
      print "unlikely matrixed: side is more than 20 dB below mid"
    } else if (d <= -12) {
      print "weak side: likely not matrixed, review visuals"
    } else if (d < -6) {
      print "ambiguous: moderate side energy"
    } else if (d <= -1) {
      print "matrix-compatible: strong side energy, not proof"
    } else {
      print "ambiguous: side is unusually strong"
    }
  }'
}

case "$padding_target_setting" in
auto | 8 | 16 | 24)
	;;
*)
	printf 'error: PADDING_TARGET_BITS must be auto, 8, 16, or 24 for SoX FLAC output\n' >&2
	exit 1
	;;
esac

case "${WRITE_FLAC:-1}" in
0 | 1)
	;;
*)
	printf 'error: WRITE_FLAC must be 0 or 1\n' >&2
	exit 1
	;;
esac

if [ "${WRITE_FLAC:-1}" = "0" ]; then
	write_flac_enabled="no"
fi

case "${STRIP_PADDING:-1}" in
0 | 1)
	;;
*)
	printf 'error: STRIP_PADDING must be 0 or 1\n' >&2
	exit 1
	;;
esac

if [ "${STRIP_PADDING:-1}" = "0" ]; then
	padding_strip_enabled="no"
fi

case "${STRICT_DUAL_MONO:-0}" in
0)
	dual_mono_mode="effective"
	;;
1)
	dual_mono_mode="strict"
	;;
*)
	printf 'error: STRICT_DUAL_MONO must be 0 or 1\n' >&2
	exit 1
	;;
esac

if ! is_db_number "$dual_mono_peak_threshold"; then
	printf 'error: DUAL_MONO_PEAK_THRESHOLD must be a dB number\n' >&2
	exit 1
fi

if ! is_db_number "$dual_mono_rms_threshold"; then
	printf 'error: DUAL_MONO_RMS_THRESHOLD must be a dB number\n' >&2
	exit 1
fi

padding_bit_depth_line="$(get_bit_depth_line "$source_stats")"
padding_max_reported_bits="$(get_max_bit_depth_bits "$source_stats")"

if [ "$padding_target_setting" = "auto" ]; then
	padding_target_bits="$(resolve_supported_flac_bits "$padding_max_reported_bits" || printf 'unknown')"
else
	padding_target_bits="$padding_target_setting"
fi

if is_positive_integer "$precision_bits" && is_nonnegative_integer "$padding_max_reported_bits" && is_positive_integer "$padding_target_bits"; then
	if [ "$precision_bits" -le "$padding_target_bits" ]; then
		if [ "$padding_target_setting" = "auto" ] && [ "$padding_max_reported_bits" -lt "$precision_bits" ] && [ "$padding_target_bits" -eq "$precision_bits" ]; then
			padding_reason="no lower SoX-supported FLAC bit depth can hold reported bit depth $padding_max_reported_bits"
		else
			padding_reason="not needed: precision bits $precision_bits are not above target bits $padding_target_bits"
		fi
	elif [ "$padding_max_reported_bits" -le "$padding_target_bits" ]; then
		padding_safe="yes"
		padding_reason="safe: SoX stats reports no bit depth above $padding_target_bits"
	else
		padding_reason="not safe: SoX stats reports bit depth up to $padding_max_reported_bits"
	fi
else
	padding_reason="unknown: could not parse precision bits or resolve a SoX-supported FLAC target"
fi

if [ "${STRIP_PADDING:-1}" = "1" ] && [ "$padding_safe" = "yes" ]; then
	flac_output_bits="$padding_target_bits"
	flac_output_reason="padding stripped: SoX stats reports no bit depth above $padding_target_bits"
elif is_supported_flac_bits "$precision_bits"; then
	flac_output_bits="$precision_bits"
	if [ "${STRIP_PADDING:-1}" = "0" ]; then
		flac_output_reason="source precision preserved because padding stripping is disabled"
	else
		flac_output_reason="source precision preserved"
	fi
else
	flac_output_bits="$(resolve_supported_flac_bits "$precision_bits" || printf 'unknown')"
	if is_positive_integer "$flac_output_bits"; then
		flac_output_reason="source precision $precision_bits rounded up to SoX-supported FLAC bit depth $flac_output_bits"
	else
		flac_output_reason="not writable: could not resolve a SoX-supported FLAC bit depth"
	fi
fi

if is_supported_flac_bits "$flac_output_bits"; then
	mono_output_bits="$flac_output_bits"
elif is_supported_flac_bits "$precision_bits"; then
	mono_output_bits="$precision_bits"
fi

make_spectrogram() {
	mode="$1"
	out_file="$2"
	start="${SPECTROGRAM_START:-0}"

	if [ -n "${SPECTROGRAM_TRIM:-}" ]; then
		set -- trim "$start" "$SPECTROGRAM_TRIM"
	elif [ "$start" != "0" ]; then
		set -- trim "$start"
	else
		set --
	fi

	case "$mode" in
	stereo)
		printf 'Generating spectrogram: stereo channels (no remix)\n' >&2
		sox "$work_input" -n "$@" spectrogram -x "$SPECTROGRAM_WIDTH" -y "$SPECTROGRAM_CHANNEL_HEIGHT" -o "$out_file"
		;;
	left)
		remix_spec="1"
		printf 'Generating spectrogram: left channel (SoX remix %s)\n' "$remix_spec" >&2
		sox "$work_input" -n "$@" remix "$remix_spec" spectrogram -x "$SPECTROGRAM_WIDTH" -y "$SPECTROGRAM_CHANNEL_HEIGHT" -o "$out_file"
		;;
	right)
		remix_spec="2"
		printf 'Generating spectrogram: right channel (SoX remix %s)\n' "$remix_spec" >&2
		sox "$work_input" -n "$@" remix "$remix_spec" spectrogram -x "$SPECTROGRAM_WIDTH" -y "$SPECTROGRAM_CHANNEL_HEIGHT" -o "$out_file"
		;;
	mid)
		remix_spec="$mid_remix_spec"
		printf 'Generating spectrogram: mid (L+R)/2 (SoX remix %s)\n' "$remix_spec" >&2
		sox "$work_input" -n "$@" remix "$remix_spec" spectrogram -x "$SPECTROGRAM_WIDTH" -y "$SPECTROGRAM_CHANNEL_HEIGHT" -o "$out_file"
		;;
	side)
		remix_spec="$side_remix_spec"
		printf 'Generating spectrogram: side (L-R)/2 (SoX remix %s)\n' "$remix_spec" >&2
		sox "$work_input" -n "$@" remix "$remix_spec" spectrogram -x "$SPECTROGRAM_WIDTH" -y "$SPECTROGRAM_CHANNEL_HEIGHT" -o "$out_file"
		;;
	esac
}

make_waveform() {
	waveform_input="$1"
	waveform_file="$2"
	raw_waveform="$tmp_dir/$(basename "$waveform_file").raw.png"
	waveform_channels="$(soxi -c "$waveform_input")"
	waveform_duration="$(soxi -D "$waveform_input")"

	ffmpeg -nostdin -hide_banner -loglevel error -y \
		-i "$waveform_input" \
		-filter_complex "showwavespic=s=1762x962:split_channels=1:colors=DodgerBlue:scale=lin:draw=scale:filter=peak" \
		-frames:v 1 \
		"$raw_waveform"

	/usr/local/lib/sox/annotate_waveform.py "$raw_waveform" "$waveform_file" "$waveform_duration" "$waveform_channels"
}

make_mid_side_audio() {
	mid_side_file="$1"

	sox "$work_input" --comment "" -b "$precision_bits" "$mid_side_file" remix "$mid_remix_spec" "$side_remix_spec"
}

if [ "${NO_SPECTROGRAMS:-0}" = "0" ]; then
	make_spectrogram stereo "$spectrogram_output" "$base spectrograms"
	spectrogram_status="written"
else
	spectrogram_status="skipped by --no-spectrograms"
fi

if [ "${NO_WAVEFORMS:-0}" = "0" ]; then
	make_waveform "$work_input" "$waveform_output"
	waveform_status="written"
else
	waveform_status="skipped by --no-waveforms"
fi

if [ "$channels" = "2" ]; then
	sox "$work_input" -n remix "$side_remix_spec" stats >"$side_stats" 2>&1
	sox "$work_input" -n remix "$mid_remix_spec" stats >"$mid_stats" 2>&1

	side_pk="$(get_pk_db "$side_stats")"
	side_rms="$(get_rms_db "$side_stats")"
	mid_pk="$(get_pk_db "$mid_stats")"
	mid_rms="$(get_rms_db "$mid_stats")"
	matrix_side_mid_delta_db="$(calc_db_delta "$side_rms" "$mid_rms")"
	matrix_correlation="$(calc_correlation_from_delta "$matrix_side_mid_delta_db")"
	matrix_status="reported"

	if [ "$side_pk" = "-inf" ] && [ "$side_rms" = "-inf" ]; then
		strict_dual_mono="yes"
	fi

	if db_at_or_below "$side_pk" "$dual_mono_peak_threshold" && db_at_or_below "$side_rms" "$dual_mono_rms_threshold"; then
		effective_dual_mono="yes"
	fi

	if [ "$dual_mono_mode" = "strict" ]; then
		dual_mono="$strict_dual_mono"
		if [ "$dual_mono" = "yes" ]; then
			dual_mono_reason="strict side digital silence"
		else
			dual_mono_reason="strict mode requires side Pk lev dB and RMS lev dB to be -inf"
		fi
	else
		dual_mono="$effective_dual_mono"
		if [ "$strict_dual_mono" = "yes" ]; then
			dual_mono_reason="strict side digital silence"
		elif [ "$dual_mono" = "yes" ]; then
			dual_mono_reason="side residual is below effective dual mono thresholds"
		else
			dual_mono_reason="side residual exceeds effective dual mono thresholds"
		fi
	fi

	if [ "$mid_pk" = "-inf" ] && [ "$mid_rms" = "-inf" ]; then
		opposite_phase_duplicate="yes"
	fi

	if [ "$dual_mono" = "yes" ]; then
		matrix_heuristic="not matrixed: dual mono"
	elif [ "$opposite_phase_duplicate" = "yes" ]; then
		matrix_heuristic="not matrixed: opposite-phase duplicate"
	else
		matrix_heuristic="$(classify_matrix_delta "$matrix_side_mid_delta_db")"
	fi

	if [ "$spectrogram_status" = "written" ]; then
		make_spectrogram left "$output_dir/$base.left.png" "$base left"
		make_spectrogram right "$output_dir/$base.right.png" "$base right"
		make_spectrogram mid "$matrix_mid_spectrogram" "$base mid"
		make_spectrogram side "$matrix_side_spectrogram" "$base side"
	fi

	if [ "$waveform_status" = "written" ]; then
		mid_side_audio="$tmp_dir/$base.mid-side.flac"
		make_mid_side_audio "$mid_side_audio"
		make_waveform "$mid_side_audio" "$matrix_mid_side_waveform"
	fi

	if [ "${NO_MONO:-0}" = "1" ]; then
		mono_status="skipped by --no-mono"
	elif [ "$dual_mono" = "yes" ]; then
		if is_supported_flac_bits "$mono_output_bits"; then
			sox -D "$work_input" --comment "" -b "$mono_output_bits" -C 8 "$mono_output" remix 1
			mono_status="written"
		else
			mono_status="skipped because mono output bit depth is unknown"
		fi
	else
		mono_status="skipped because dual mono is no"
	fi
else
	printf 'Skipped: input has %s channels, not 2.\n' "$channels" >"$side_stats"
	printf 'Skipped: input has %s channels, not 2.\n' "$channels" >"$mid_stats"
	mono_status="skipped because input is not stereo"
	matrix_status="skipped because input is not stereo"
	dual_mono_reason="skipped because input is not stereo"
fi

if [ "${WRITE_FLAC:-1}" = "1" ]; then
	if is_supported_flac_bits "$flac_output_bits"; then
		sox -D "$work_input" --comment "" -b "$flac_output_bits" -C 8 "$flac_output"
		flac_output_status="written"
	else
		flac_output_status="skipped because $flac_output_reason"
	fi
else
	flac_output_status="skipped by --no-write-flac"
fi

if [ "${STRIP_PADDING:-1}" = "0" ]; then
	padding_status="disabled by --no-strip-padding"
elif [ "$padding_safe" = "yes" ]; then
	if [ "$flac_output_status" = "written" ]; then
		padding_status="applied to FLAC output"
	else
		padding_status="available; FLAC output skipped"
	fi
else
	padding_status="not applied; $padding_reason"
fi

{
	printf 'SoX stereo analysis report\n'
	printf '\n'
	printf 'Input: %s\n' "$input"
	printf 'Analysis input: %s\n' "$work_input"
	printf 'Decode step: %s\n' "$decode_note"
	printf 'SoX version: %s\n' "$(sox --version)"
	if command -v ffmpeg >/dev/null 2>&1; then
		printf 'FFmpeg available: yes\n'
	else
		printf 'FFmpeg available: no\n'
	fi
	printf '\n'
	printf 'Channels: %s\n' "$channels"
	printf 'Sample rate: %s\n' "$sample_rate"
	printf 'Precision bits: %s\n' "$precision_bits"
	printf 'Duration seconds: %s\n' "$duration_seconds"
	printf '\n'
	printf 'FLAC output\n'
	printf 'FLAC output enabled: %s\n' "$write_flac_enabled"
	printf 'FLAC output status: %s\n' "$flac_output_status"
	printf 'FLAC output bits: %s\n' "$flac_output_bits"
	printf 'FLAC output reason: %s\n' "$flac_output_reason"
	if [ "$flac_output_status" = "written" ]; then
		printf 'FLAC output: %s\n' "$flac_output"
	fi
	printf '\n'
	printf 'Padding analysis\n'
	printf 'SoX stats bit-depth: %s\n' "$padding_bit_depth_line"
	printf 'Max reported bit depth: %s\n' "$padding_max_reported_bits"
	printf 'Padding target setting: %s\n' "$padding_target_setting"
	printf 'Resolved padding target bits: %s\n' "$padding_target_bits"
	printf 'SoX-supported FLAC bits: %s\n' "$padding_supported_flac_bits"
	printf 'Padding stripping enabled: %s\n' "$padding_strip_enabled"
	printf 'Padding strip safe: %s\n' "$padding_safe"
	printf 'Padding reason: %s\n' "$padding_reason"
	printf 'Padding strip status: %s\n' "$padding_status"
	printf '\n'
	printf 'side test: (L-R)/2\n'
	printf 'side Pk lev dB: %s\n' "$side_pk"
	printf 'side RMS lev dB: %s\n' "$side_rms"
	printf 'Dual mono decision mode: %s\n' "$dual_mono_mode"
	printf 'Effective side Pk threshold dB: %s\n' "$dual_mono_peak_threshold"
	printf 'Effective side RMS threshold dB: %s\n' "$dual_mono_rms_threshold"
	printf 'Strict dual mono: %s\n' "$strict_dual_mono"
	printf 'Effective dual mono: %s\n' "$effective_dual_mono"
	printf 'Dual mono: %s\n' "$dual_mono"
	printf 'Dual mono reason: %s\n' "$dual_mono_reason"
	printf '\n'
	printf 'Opposite-phase duplicate test: mid (L+R)/2\n'
	printf 'mid Pk lev dB: %s\n' "$mid_pk"
	printf 'mid RMS lev dB: %s\n' "$mid_rms"
	printf 'Opposite-phase duplicate: %s\n' "$opposite_phase_duplicate"
	printf '\n'
	printf 'Matrix stereo analysis\n'
	printf 'Matrix status: %s\n' "$matrix_status"
	printf 'side minus mid RMS dB: %s\n' "$matrix_side_mid_delta_db"
	printf 'Estimated L/R correlation: %s\n' "$matrix_correlation"
	printf 'Matrix heuristic: %s\n' "$matrix_heuristic"
	printf '\n'
	printf 'Spectrogram status: %s\n' "$spectrogram_status"
	if [ -n "${SPECTROGRAM_TRIM:-}" ]; then
		printf 'Spectrogram trim seconds: %s\n' "$SPECTROGRAM_TRIM"
	else
		printf 'Spectrogram trim seconds: full input\n'
	fi
	printf 'Spectrogram start position: %s\n' "${SPECTROGRAM_START:-0}"
	printf 'Waveform status: %s\n' "$waveform_status"
	printf 'FLAC output status: %s\n' "$flac_output_status"
	if [ "$flac_output_status" = "written" ]; then
		printf 'FLAC output: %s\n' "$flac_output"
	fi
	printf 'Mono output status: %s\n' "$mono_status"
	if [ "$mono_status" = "written" ]; then
		printf 'Mono output: %s\n' "$mono_output"
		printf 'Mono output bits: %s\n' "$mono_output_bits"
	fi
	printf 'Padding strip status: %s\n' "$padding_status"
	printf '\n'
	printf 'Files:\n'
	printf '%s\n' "- Source info: $source_info"
	printf '%s\n' "- Source stats: $source_stats"
	printf '%s\n' "- side stats: $side_stats"
	printf '%s\n' "- mid stats: $mid_stats"
	if [ "$flac_output_status" = "written" ]; then
		printf '%s\n' "- FLAC output: $flac_output"
	fi
	if [ "$spectrogram_status" = "written" ]; then
		printf '%s\n' "- Spectrograms: $spectrogram_output"
		if [ "$channels" = "2" ]; then
			printf '%s\n' "- Left spectrogram: $output_dir/$base.left.png"
			printf '%s\n' "- Right spectrogram: $output_dir/$base.right.png"
			printf '%s\n' "- Matrix mid spectrogram: $matrix_mid_spectrogram"
			printf '%s\n' "- Matrix side spectrogram: $matrix_side_spectrogram"
		fi
	fi
	if [ "$waveform_status" = "written" ]; then
		printf '%s\n' "- Waveforms: $waveform_output"
		if [ "$channels" = "2" ]; then
			printf '%s\n' "- Matrix mid-side waveforms: $matrix_mid_side_waveform"
		fi
	fi
	printf '\n'
	printf 'Notes:\n'
	printf '%s\n' '- The mid and side signals are scaled as (L+R)/2 and (L-R)/2 to prevent derived-signal clipping.'
	printf '%s\n' '- Strict dual mono requires both side Pk lev dB and RMS lev dB to be -inf.'
	printf '%s\n' '- Effective dual mono uses configurable side peak and RMS thresholds.'
	printf '%s\n' '- Matrixed stereo is never stripped automatically; mono output is written only when the dual mono decision passes.'
	printf '%s\n' '- Matrix stereo analysis reports evidence from mid and side energy; it is not a bit-exact proof.'
	printf '%s\n' '- Mono output keeps channel 1 unchanged and clears copied comments.'
	printf '%s\n' '- SoX reports effective bit depth but does not lower FLAC output precision automatically.'
	printf '%s\n' '- Padding stripping applies to the canonical FLAC output and uses sox -D to disable automatic dither.'
} >"$report"

if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
	chown -R "$HOST_UID:$HOST_GID" "$output_dir" 2>/dev/null || true
fi

printf 'Report: %s\n' "$report"
printf 'Dual mono: %s\n' "$dual_mono"
printf 'Strict dual mono: %s\n' "$strict_dual_mono"
printf 'FLAC output status: %s\n' "$flac_output_status"
printf 'Mono output status: %s\n' "$mono_status"
printf 'Padding strip safe: %s\n' "$padding_safe"
printf 'Padding strip status: %s\n' "$padding_status"
