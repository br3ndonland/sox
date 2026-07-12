# README

## Description

This repo builds a Docker container image that can be used to run [SoX](https://sourceforge.net/projects/sox/) (Sound eXchange). Other tools include [FFmpeg](https://ffmpeg.org/), [MKVToolNix](https://mkvtoolnix.download/), [MediaInfo](https://mediaarea.net/en/MediaInfo), [jq](https://jqlang.org/manual/), and [uv](https://docs.astral.sh/uv/). The waveform annotation script also uses [Pillow](https://pillow.readthedocs.io/en/stable/index.html).

The entrypoint can analyze individual audio files or Matroska video files (`.mkv`). By default, MKVs are analyzed by decoding lossless mono and stereo audio tracks in the file, analyzing them, remuxing replacement FLAC tracks, and optionally overwriting the original MKV after a successful remux.

## Usage

### Audio files

The Docker container runs [`entrypoint.sh`](./sox/entrypoint.sh). The entrypoint script accepts the path to a media file. Bind mount a media directory at `/opt/media` and pass an input path inside that directory.

For a file at `/path/to/media/file.flac`:

```sh
docker run --rm -it -u "$(id -u):$(id -g)" -v /path/to/media:/opt/media ghcr.io/br3ndonland/sox file.flac
```

Audio files are analyzed with [`analyze_audio.sh`](./sox/analyze_audio.sh), which writes reports, stats, spectrograms, waveforms, and FLAC outputs.

### MKV files

For `.mkv` inputs, the entrypoint uses `mkvmerge -J` to discover audio tracks and MediaInfo to determine their compression modes. By default, every lossless mono or stereo audio track is decoded to FLAC, analyzed, and replaced in a remuxed MKV. Lossy tracks are preserved.

```sh
docker run --rm -it -u "$(id -u):$(id -g)" -v /path/to/media:/opt/media ghcr.io/br3ndonland/sox file.mkv
```

By default in MKV mode, **the original file will be overwritten after the conversion process is complete.** Although the converted file will be the same size or smaller than the source file, the conversion process will temporarily require additional disk space.

To avoid overwriting the input file, use the `--mkv-output <file_path>` option.

```sh
docker run --rm -it -u "$(id -u):$(id -g)" -v /path/to/media:/opt/media ghcr.io/br3ndonland/sox --mkv-output file.sox.mkv file.mkv
```

Analyze and replace only selected MKV track IDs:

```sh
docker run --rm -it -u "$(id -u):$(id -g)" -v /path/to/media:/opt/media ghcr.io/br3ndonland/sox --mkv-tracks 1,2 file.mkv
```

Explicit `--mkv-tracks` selections can include lossy tracks, but selected tracks must still be mono or stereo.

`--mkv-tracks` uses MKV track IDs from `mkvmerge -J`, not FFmpeg stream indexes. List track IDs with:

```sh
docker run --rm -it -u "$(id -u):$(id -g)" -v /path/to/media:/opt/media --entrypoint mkvmerge ghcr.io/br3ndonland/sox -J file.mkv
```

Unselected audio tracks, unsupported audio tracks, video tracks, subtitle tracks, chapters, and attachments are preserved by the remux. Selected mono or stereo audio tracks are replaced with the analyzed FLAC output. If a selected stereo track is detected as dual mono and mono output is enabled, the replacement is the single-channel mono FLAC output. Otherwise, the replacement is the normalized FLAC output.

MKV remuxing requires replacement FLAC files, so `--no-write-flac` is rejected in MKV mode.

### Analysis options

The entrypoint accepts the same analysis options for direct audio and MKV track analysis:

- `-o, --output-dir DIR`: write reports and outputs to `DIR`.
- `--spectrogram-trim SEC`: generate spectrograms for `SEC` seconds while detection scans the full input.
- `--spectrogram-start POS`: start spectrograms at `POS`; default `0`.
- `--spectrogram-width PX`: spectrogram plot width; default `3000`.
- `--spectrogram-height PX`: spectrogram height per channel; default `513`.
- `--no-waveforms`: skip waveform PNG generation.
- `--no-spectrograms`: skip PNG spectrogram generation.
- `--no-mono`: do not write mono FLAC output for dual mono stereo tracks.
- `--strict-dual-mono`: require exact side digital silence for dual mono.
- `--dual-mono-peak-threshold DB`: effective dual mono side peak threshold; default `-86.02`.
- `--dual-mono-rms-threshold DB`: effective dual mono side RMS threshold; default `-126.02`.
- `--write-flac`: write normalized FLAC output; default enabled.
- `--no-write-flac`: skip normalized FLAC output. This cannot be used in MKV mode.
- `--strip-padding`: strip FLAC padding when safe; default enabled.
- `--no-strip-padding`: preserve decoded source precision.
- `--padding-target-bits N`: target bit depth for padding stripping. Use `auto`, `8`, `16`, or `24`; default `auto`.

The side signal uses `(L-R)/2`, so its amplitude is 6.02 dB below the unscaled `L-R` signal: `20 log10(0.5) = -6.0206 dB`. The default side thresholds of `-86.02` dB peak and `-126.02` dB RMS therefore preserve the same dual-mono decision boundaries as `-80` dB and `-120` dB applied to unscaled `L-R`.

### Interactive usage

Use an alternate entrypoint to keep the container open for interactive work.

```sh
docker run --rm -it -u "$(id -u):$(id -g)" -v /path/to/media:/opt/media --entrypoint sh ghcr.io/br3ndonland/sox
```

### Users

Docker containers run as `root` by default. For bind-mounted media directories, use `-u "$(id -u):$(id -g)"` so outputs are owned by the host user.

The image also includes a non-root `apps` user and group with UID and GID `568`.

```sh
docker run --rm -it -u apps -v /path/to/media:/opt/media --entrypoint sh ghcr.io/br3ndonland/sox
```

## Outputs

By default, analysis outputs are written to the input file's directory. For example, an input at `/opt/media/subdir/file.flac` writes its outputs to `/opt/media/subdir/`. Override this location with `--output-dir`.

Each analyzed audio file or MKV track writes:

- `INPUT_BASENAME.audio.report.txt`
- `INPUT_BASENAME.audio.source.txt`
- `INPUT_BASENAME.audio.stats.source.txt`
- `INPUT_BASENAME.audio.stats.side-l-minus-r.txt`
- `INPUT_BASENAME.audio.stats.mid-l-plus-r.txt`
- `INPUT_BASENAME.audio.flac`
- `INPUT_BASENAME.audio.spectrograms.png`
- `INPUT_BASENAME.audio.waveforms.png`

Stereo inputs also write channel and mid/side visualizations:

The mid and side signals use `(L+R)/2` and `(L-R)/2`, respectively, so they remain within full scale before statistics and spectrogram generation.

- `INPUT_BASENAME.audio.left.png`
- `INPUT_BASENAME.audio.right.png`
- `INPUT_BASENAME.audio.mid-l-plus-r.png`
- `INPUT_BASENAME.audio.side-l-minus-r.png`
- `INPUT_BASENAME.audio.mid-side-waveforms.png`

If the selected dual mono decision passes, analysis also writes:

```text
INPUT_BASENAME.audio.mono.flac
```

MKV mode also writes:

```text
INPUT_BASENAME.audio.mkv.report.txt
```

That report lists replaced tracks and preserved or skipped audio tracks. MKV track outputs include the track ID after `.audio`, for example `INPUT_BASENAME.audio.track-1.report.txt`.

## Development

### Summary

- Docker container images are built with GitHub Actions using [`.github/workflows/ci.yml`](./.github/workflows/ci.yml).
- The GitHub Actions container build runs [`scripts/build.sh`](./scripts/build.sh).
- [`mise.toml`](./mise.toml) installs and runs local development tools with [mise-en-place](https://mise.jdx.dev/).
- Shell scripts are checked with ShellCheck and formatted with `shfmt`.
- JSON, Markdown, and YAML files are formatted with Prettier.

### IDE integration

Suggested VSCode extensions and settings are provided in [`.vscode`](./.vscode).

For VSCode IDE integration with uv scripts:

1. Identify the virtual environment that uv is using for the script ([astral-sh/uv#16171](https://github.com/astral-sh/uv/issues/16171)).
   ```sh
   uv sync --script sox/annotate_waveform.py --output-format json --quiet |
     jq -r '@text "\(.sync.environment.path)/bin/python"' | pbcopy
   ```
2. Set the Python interpreter to the one from the virtual environment _(Command Palette -> Python: Select Interpreter -> Enter interpreter path -> paste)_.

### Local container image builds

The [`build.sh`](scripts/build.sh) script can be used to build Docker container images locally. The [`.env.local`](.env.local) file includes required environment variables for local builds.

```sh
(source .env.local && ./scripts/build.sh)
```

The version-controlled `.env.local` file uses shell `export` assignments so it can be sourced before running the build script.

If this scaffold has not been initialized as a Git repository yet, `scripts/build.sh` uses a zero SHA placeholder for the local image tag.

To build a runnable local image, keep `LOAD=true`, set `PLATFORMS` to one platform, and use manifest-only annotations.

```sh
export DOCKER_METADATA_ANNOTATIONS_LEVELS="manifest"
export LOAD="true"
export PLATFORMS="linux/amd64"
export TAG_LATEST="true"
```

Optional environment variables include:

- `BUILD_ARGS`: whitespace-separated Docker build arguments, such as `UV_PYTHON=3.14 FOO=bar`.
- `BUILD_CONTEXT`: should be set to `./sox`.
- `DOCKERFILE`: should be set to `./sox/Dockerfile`.
- `DOCKER_METADATA_ANNOTATIONS_LEVELS`: comma-separated list of Docker Buildx annotation levels. Use `manifest` for single-platform local builds.
- `DOCKER_METADATA_SHORT_SHA_LENGTH`: number of characters for short SHA tags; default `7`.
- `PLATFORMS`: comma-separated target platforms.
- `LOAD`: set to `true` or `1` to load the image into the local Docker image store.
- `OCI_SOURCE`: OCI image source URL. Defaults to `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}`.
- `OCI_TITLE`: OCI image title. Defaults to the repository name.
- `TAG_LATEST`: set to `true` or `1` to tag the image with `${IMAGE_NAME}:latest`.
- `PROVENANCE`: set to `false` or `0` to skip BuildKit provenance attestations.
- `GHA_CACHE`: set to `true` or `1` to use the Docker Buildx GitHub Actions cache backend.

### Checks

Run checks with mise-en-place:

```sh
mise run check
```

## License

This project is dedicated to the public domain under the CC0 1.0 Universal license. See [LICENSE](./LICENSE).
